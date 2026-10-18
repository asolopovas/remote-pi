package android.os;
import java.util.*;
public class Handler {
  private static volatile long now;
  private static final List<Entry> queue = new ArrayList<>();
  private record Entry(Runnable task, long at) {}
  public Handler(Looper looper) {}
  public boolean post(Runnable task) { return postDelayed(task,0); }
  public synchronized boolean postDelayed(Runnable task,long delay) { synchronized(queue){queue.add(new Entry(task,now+delay));} return true; }
  public void removeCallbacks(Runnable task) { synchronized(queue){queue.removeIf(e -> e.task==task);} }
  public static void advance(long delta) {
    long end=now+delta;
    while(true) {
      Entry first;
      synchronized(queue){first=queue.stream().filter(e -> e.at<=end).min(Comparator.comparingLong(e -> e.at)).orElse(null);
      if(first!=null)queue.remove(first);}
      if(first==null) break;
      now=first.at; first.task.run();
    }
    now=end;
  }
  public static void reset() { synchronized(queue){queue.clear(); now=0;} }
}
