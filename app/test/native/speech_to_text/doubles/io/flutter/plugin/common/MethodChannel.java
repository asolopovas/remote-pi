package io.flutter.plugin.common; import java.util.*;
public class MethodChannel {
 public interface Result {void success(Object o);void error(String code,String message,Object details);void notImplemented();}
 public interface MethodCallHandler {void onMethodCall(MethodCall call,Result result);}
 public record Event(String method,Object arguments) {}
 public final List<Event> events=new ArrayList<>();
 public MethodChannel(BinaryMessenger messenger,String name){}
 public void setMethodCallHandler(MethodCallHandler handler){}
 public void invokeMethod(String method,Object arguments){events.add(new Event(method,arguments));}
}
