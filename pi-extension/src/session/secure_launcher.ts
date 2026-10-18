import type { AgentRequest, LauncherRequest, ManagedAgent, ServerMessage } from "../protocol/types.js";
import type { Ed25519Keypair } from "../pairing/crypto.js";
import { ManagedAgents } from "./managed_agents.js";
import { rpcSpawnArgs } from "../daemon/rpc_child.js";
import { LaunchRegistry, type LaunchProject } from "./launch_store.js";
import { LaunchSecurity } from "./launch_security.js";
import { launchSandbox } from "./launch_sandbox.js";
import { ManagedRoom } from "./managed_transport.js";
import { resolveRelayUrl, toWebSocketUrl } from "../config.js";
interface Options {
  cwd: string; extensionPath: string; keypair(): Promise<Ed25519Keypair>;
  paired(owner: string): Promise<boolean>; current(): boolean;
  registry?: LaunchRegistry;
  /** Actual currently published root room, never reconstructed from cwd/name. */
  rootRoom?(): string | undefined;
}
/** Protected launch surface. Legacy arbitrary-cwd mutations are deliberately
 * refused, not silently mapped to a guessed registry entry. */
export class SecureLauncher {
  readonly agents: ManagedAgents;
  readonly security: LaunchSecurity;
  private readonly registry: LaunchRegistry;
  private readonly projects = new Map<string, LaunchProject>();
  private readonly mutations = new Map<string, string>();
  private readonly rooms = new Map<string, ManagedRoom>();
  private closing = false;
  private shuttingDown = false;
  constructor(private readonly opts: Options) {
    this.registry = opts.registry ?? new LaunchRegistry();
    this.agents = new ManagedAgents({ cwd: opts.cwd, extensionPath: opts.extensionPath,
      admitted: (owner, id) => {
        const payload = this.mutations.get(JSON.stringify([owner, id]));
        return !!payload && !this.closing && !this.shuttingDown && opts.current() && this.security.hasGrant(owner, (JSON.parse(payload) as { epoch: string }).epoch);
      },
      prepareSpawn: async (agent, owner, requestId) => {
        const project = this.projects.get(JSON.stringify([owner, requestId]));
        if (!project || agent.cwd !== project.cwd.path) throw new Error("Unknown registered project");
        const plan = await launchSandbox(project, opts.extensionPath, rpcSpawnArgs(opts.extensionPath, agent.name, false).filter(a => a !== "--approve"), agent.name);
        return { command: plan.command, args: plan.args, options: { cwd: project.cwd.path, env: plan.env, stdio: ["pipe", "pipe", "pipe", "pipe", ...plan.fds] }, pipe: true, expectedModel: plan.expectedModel, close: plan.close };
      },
      publish: async (agent: ManagedAgent, owner, child) => {
        const epoch = this.security.epoch;
        const keypair = await opts.keypair();
        if (!await opts.paired(owner) || !await this.security.authorized(owner, epoch) || this.closing || this.shuttingDown || !opts.current() || epoch !== this.security.epoch || !this.security.hasGrant(owner, epoch)) throw new Error("Host authority changed");
        const rootRoom = opts.rootRoom?.();
        const publicationCurrent = () => !this.closing && !this.shuttingDown && opts.current() && epoch === this.security.epoch && this.security.hasGrant(owner, epoch) && this.agents.ownsChild(owner, agent.agent_id, child);
        const room = new ManagedRoom({ agent, owner, child, keypair, publication: { current: publicationCurrent, authorized: async () => await opts.paired(owner) && await this.security.authorized(owner, epoch) && publicationCurrent() }, url: toWebSocketUrl(resolveRelayUrl().url),
          launchingHost: rootRoom ? { room_id: rootRoom, launcher_id: this.agents.launcherId } : undefined,
          access: epoch => this.security.access(owner, epoch),
          currentEpoch: () => this.security.epoch,
          ownsChild: () => this.agents.ownsChild(owner, agent.agent_id, child),
          stopChild: authorized => this.agents.stopOwnedChild(owner, agent.agent_id, child, authorized),
          paired: async () => !this.closing && opts.current() && await opts.paired(owner),
          current: () => !this.closing && opts.current() && (!rootRoom || opts.rootRoom?.() === rootRoom),
          hasGrant: epoch => !this.closing && !this.shuttingDown && opts.current() && this.security.hasGrant(owner, epoch),
          authorized: async epoch => {
            if (!await opts.paired(owner)) { this.lock(); return false; }
            return !this.closing && !this.shuttingDown && opts.current() && await this.security.authorized(owner, epoch);
          },
        });
        this.rooms.set(agent.agent_id, room);
        try { await room.connect(); } catch (error) { this.rooms.delete(agent.agent_id); throw error; }
        return () => { room.close(); this.rooms.delete(agent.agent_id); };
      },
    });
    this.security = new LaunchSecurity(this.agents.launcherId, this.registry.dir);
  }
  lock(): void { this.security.lock(); for (const room of this.rooms.values()) room.revoke(); }
  async legacy(owner: string, request: AgentRequest, paired: () => Promise<boolean>): Promise<ServerMessage> {
    if (request.type !== "agent_list") return { type: "error", in_reply_to: request.id, code: "invalid_message", message: "Use registered project_launch or launcher_agent_stop with current PIN authority" };
    const epoch = this.security.epoch;
    return this.agents.handle(owner, request, async () => !this.closing && !this.shuttingDown && this.opts.current() && await paired() && await this.security.authorized(owner, epoch));
  }
  async handle(owner: string, request: LauncherRequest, paired: () => Promise<boolean>, channelCurrent: () => boolean = () => true): Promise<ServerMessage> {
    const deny = (): ServerMessage => ({ type: "error", in_reply_to: request.id, code: "invalid_message", message: "Launcher request denied; refresh status, unlock or inspect local project/PIN setup" });
    const stillCurrent = () => !this.closing && !this.shuttingDown && this.opts.current() && channelCurrent();
    const current = async () => {
      if (!await paired()) { this.lock(); return false; }
      return stillCurrent();
    };
    if (!await current()) return deny();
    if (request.type === "launcher_status") return { type: "launcher_status_result", in_reply_to: request.id, status: await this.security.status(owner) };
    if (request.type === "project_list") {
      const epoch = this.security.epoch;
      if (!await this.security.authorized(owner, epoch)) return deny();
      try {
        const projects = await this.registry.list();
        if (!await current() || !await this.security.authorized(owner, epoch)) return deny();
        return { type: "project_list_result", in_reply_to: request.id, projects: projects.map(p => ({ project_id: p.id, name: p.name, cwd: p.cwd.path, allowed_folders: p.folders.map(f => f.path) })) };
      } catch { return deny(); }
    }
    if (!("launcher_id" in request) || request.launcher_id !== this.agents.launcherId || request.epoch !== this.security.epoch) return deny();
    if (request.type === "launcher_unlock" || request.type === "launcher_pin_initialize") {
      try {
        if (request.type === "launcher_pin_initialize") await this.security.initialize(owner, request.id, request.launcher_id, request.epoch, request.pin, current, stillCurrent);
        else await this.security.unlock(owner, request.id, request.launcher_id, request.epoch, request.pin, current);
        for (const room of this.rooms.values()) room.revoke();
      }
      catch { return deny(); }
      return { type: "launcher_status_result", in_reply_to: request.id, status: await this.security.status(owner) };
    }
    const epoch = request.epoch;
    const authorized = async () => await current() && await this.security.authorized(owner, epoch);
    if (request.type === "launcher_lock") {
      // A currently paired owner may revoke access even while locked; cannot unlock.
      this.lock();
      return { type: "launcher_status_result", in_reply_to: request.id, status: await this.security.status(owner) };
    }
    if (!await authorized()) return deny();
    const key = JSON.stringify([owner, request.id]);
    const payload = JSON.stringify(request);
    const previous = this.mutations.get(key);
    if (previous && previous !== payload || !previous && this.mutations.size >= 256) return deny();
    this.mutations.set(key, payload);
    if (request.type === "launcher_shutdown") {
      this.shuttingDown = true;
      this.lock();
      try {
        const stopped = await this.agents.shutdownOwner(owner);
        return { type: "launcher_shutdown_result", in_reply_to: request.id, stopped, status: await this.security.status(owner) };
      } finally { this.shuttingDown = false; }
    }
    if (request.type === "launcher_agent_stop") return this.agents.handle(owner, { type: "agent_stop", id: request.id, agent_id: request.agent_id }, authorized);
    if (request.type !== "project_launch") return deny();
    try {
      const project = (await this.registry.list()).find(p => p.id === request.project_id);
      if (!project || !await authorized()) return deny();
      this.projects.set(key, project);
      return await this.agents.handle(owner, { type: "agent_launch", id: request.id, launcher_id: request.launcher_id, cwd: project.cwd.path, ...(request.name ? { name: request.name } : {}) }, authorized);
    } catch { return deny(); }
    finally { this.projects.delete(key); }
  }
  async shutdown(): Promise<void> { this.closing = true; this.lock(); await this.agents.shutdown(); for (const room of this.rooms.values()) room.close(); this.rooms.clear(); }
}
