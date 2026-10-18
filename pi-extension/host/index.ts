// Load source through Pi's extension loader so every transitive host API import
// uses Pi's module mapping. Never point this entry at the standalone dist tree.
export { default } from "../src/index.js";
