import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.speech.SpeechRecognizer;
import androidx.core.content.ContextCompat;
import com.csdcorp.speech_to_text.SpeechToTextPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.lang.reflect.Field;
import java.util.*;

/** Executes the actual Gradle-compiled production plugin, not a lifecycle copy.
 * The Android engine, clock and Flutter channel are explicit JVM doubles.
 */
public class SpeechToTextPluginTest {
    static int assertions;
    static void check(boolean value, String message) {
        assertions++;
        if (!value) throw new AssertionError(message);
    }
    static class Reply implements MethodChannel.Result {
        Object value; int calls;
        public void success(Object v) { value=v; calls++; }
        public void error(String c,String m,Object d) { throw new AssertionError(c+": "+m); }
        public void notImplemented() { throw new AssertionError("notImplemented"); }
    }
    static class Fixture {
        final SpeechToTextPlugin plugin=new SpeechToTextPlugin();
        final MethodChannel channel=new MethodChannel(null,"test");
        Fixture() throws Exception {
            set("pluginContext",new Context()); set("channel",channel);
        }
        void set(String name,Object value) throws Exception {
            Field field=SpeechToTextPlugin.class.getDeclaredField(name);
            field.setAccessible(true); field.set(plugin,value);
        }
        Object get(String name) throws Exception {
            Field field=SpeechToTextPlugin.class.getDeclaredField(name);
            field.setAccessible(true); return field.get(plugin);
        }
        Reply call(String name,Map<String,Object> args) {
            Reply result=new Reply(); plugin.onMethodCall(new MethodCall(name,args),result);
            Handler.advance(0); check(result.calls==1,"exactly one reply: "+name); return result;
        }
        Reply initialize() { return call("initialize",Map.of("noBluetooth",true)); }
        Reply listen(int id) { return call("listen",Map.of("captureId",id,"onDevice",true,"listenMode",1,"partialResults",true,"localeId","en_US","listenFor",60000,"pauseFor",60000)); }
        SpeechRecognizer recognizer() { return SpeechRecognizer.created.get(SpeechRecognizer.created.size()-1); }
        List<Object> payloads(String method) {
            List<Object> result=new ArrayList<>();
            for(var event:channel.events) if(event.method().equals(method)) result.add(((Map<?,?>)event.arguments()).get("payload"));
            return result;
        }
        boolean status(String value) { return payloads("notifyStatus").contains(value); }
    }
    static Fixture fresh() throws Exception {
        long until=System.currentTimeMillis()+2000;
        for(var audio:android.media.AudioRecord.created) {
            while(!audio.released && System.currentTimeMillis()<until)Thread.sleep(5);
            check(audio.released,"previous capture worker released");
        }
        Handler.reset(); SpeechRecognizer.reset(); ContextCompat.granted=true;
        ContextCompat.bluetoothGranted=false;
        androidx.core.app.ActivityCompat.requested=null;
        Build.VERSION.SDK_INT=33; return new Fixture();
    }
    static Bundle words(String text) {
        Bundle bundle=new Bundle();
        bundle.putStringArrayList("results_recognition",new ArrayList<>(List.of(text)));
        return bundle;
    }
    static void privacyAndCapability() throws Exception {
        for(int sdk:new int[]{21,30,31,32}) {
            Fixture f=fresh(); Build.VERSION.SDK_INT=sdk;
            check(Boolean.FALSE.equals(f.initialize().value),"API33+ continuous capture required");
            check(Boolean.FALSE.equals(f.listen(1).value),"unsupported API fails closed");
            check(SpeechRecognizer.created.isEmpty(),"no recognizer on unsupported API");
        }
        for(int failure=0;failure<5;failure++) {
            Fixture f=fresh(); f.initialize();
            if(failure==0) SpeechRecognizer.available=false;
            if(failure==1) SpeechRecognizer.failCreate=true;
            if(failure==2) SpeechRecognizer.failStart=true;
            if(failure==3) SpeechRecognizer.supportError=true;
            if(failure==4) android.media.AudioRecord.failStart=true;
            check(Boolean.FALSE.equals(f.listen(7).value),"creation/support/audio/start failure closed");
            android.media.AudioRecord.failStart=false;
            check(!f.status("listening"),"startup failure not Listening");
            check(f.payloads("notifyError").size()==1,"startup error surfaced");
            check(SpeechRecognizer.genericCreates==0,"no generic fallback");
        }
        Fixture f=fresh(); ContextCompat.bluetoothGranted=true; f.initialize();
        check(Boolean.TRUE.equals(f.get("bluetoothDisabled")),"handset opt-out overrides granted Bluetooth permission");
        check(f.get("bluetoothAdapter")==null && f.get("bluetoothHeadset")==null,"no Bluetooth profile setup");
        check(Boolean.FALSE.equals(f.call("listen",Map.of("captureId",1,"onDevice",false,"listenMode",1)).value),"reject non-local");
        f.call("initialize",Map.of("intentLookup",true)); f.listen(2);
        check(SpeechRecognizer.genericCreates==0,"intent lookup cannot bypass local factory");
        check(Boolean.TRUE.equals(f.recognizer().intent.extras.get("android.speech.extra.PREFER_OFFLINE")),"local intent");
        f.call("cancel",Map.of());
    }
    static void finalAndGeneration() throws Exception {
        Fixture f=fresh(); f.initialize(); f.listen(1); SpeechRecognizer first=f.recognizer();
        first.listener.onPartialResults(words("hello"));
        first.listener.onPartialResults(words("hello wonderful"));
        f.call("stop",Map.of());
        check(first.stops==0 && first.destroys==0,"Stop sends EOF, retains final listener without stopListening");
        first.listener.onSegmentResults(words("hello wonderful world"));
        first.listener.onEndOfSegmentedSession();
        check(f.payloads("textRecognition").get(3).toString().contains("hello wonderful world"),"corrected final after Stop");
        check(first.destroys==1,"final releases once");
        f.listen(2); SpeechRecognizer second=f.recognizer();
        int size=f.channel.events.size();
        first.listener.onResults(words("stale")); first.listener.onError(5);
        first.listener.onEndOfSpeech(); first.listener.onSegmentResults(words("stale"));first.listener.onEndOfSegmentedSession();
        check(size==f.channel.events.size(),"old listener cannot reach new capture");
        Handler.advance(2000); check(second.destroys==0,"old timer cannot close new capture");
        f.call("cancel",Map.of());size=f.channel.events.size();second.listener.onResults(words("late"));
        check(size==f.channel.events.size(),"cancel rejects final");
        f.listen(2);size=f.channel.events.size();second.listener.onSegmentResults(words("reused token"));
        check(size==f.channel.events.size(),"listener identity fences token reuse");f.call("cancel",Map.of());
    }
    static void continuousCaptureAndStop() throws Exception {
        Fixture f=fresh();f.initialize();f.listen(1);SpeechRecognizer r=f.recognizer();
        check(r.supportIntent==r.intent,"preflight uses exact start intent");
        check(r.intent.extras.get("android.speech.extra.SEGMENTED_SESSION").equals("android.speech.extra.AUDIO_SOURCE"),"documented pipe selector");
        check(r.intent.extras.get("android.speech.extra.AUDIO_SOURCE") instanceof android.os.ParcelFileDescriptor,"source is descriptor not URI");
        check(r.intent.extras.get("android.speech.extra.AUDIO_SOURCE_SAMPLING_RATE").equals(16000),"explicit 16 kHz");
        check(r.intent.extras.get("android.speech.extra.AUDIO_SOURCE_CHANNEL_COUNT").equals(1),"mono");
        check(r.intent.extras.get("android.speech.extra.AUDIO_SOURCE_ENCODING").equals(2),"PCM16");
        var reader=(android.os.ParcelFileDescriptor)r.intent.extras.get("android.speech.extra.AUDIO_SOURCE");
        r.listener.onEndOfSpeech();Handler.advance(120000);
        check(!reader.closed && r.destroys==0 && !f.status("notListening"),"silence before first segment never closes stream or starts cap/watchdog");
        r.listener.onSegmentResults(words("repeat"));
        r.listener.onEndOfSpeech();r.listener.onPartialResults(words("repea"));r.listener.onSegmentResults(words("repeat"));
        check(f.payloads("textRecognition").get(2).toString().contains("repeat repeat"),"repeated phrases retained exactly");
        Handler.advance(120000);check(r.destroys==0,"no cap after words either");
        f.call("stop",Map.of());f.call("stop",Map.of());
        check(reader.closed && r.stops==0,"explicit Stop closes source idempotently");
        r.listener.onSegmentResults(words("last words"));r.listener.onEndOfSegmentedSession();
        String last=f.payloads("textRecognition").get(4).toString();
        check(last.contains("repeat repeat last words") && last.contains("resultType=2"),"all segments sealed final after EOF");
        check(r.destroys==1,"terminal callback releases once");
        f.listen(2);r=f.recognizer();f.call("stop",Map.of());Handler.advance(1999);
        check(r.destroys==0,"Stop final window remains");Handler.advance(1);check(r.destroys==1,"bounded final timeout releases");
    }
    static void ignoredSourceFailsWithoutRestart() throws Exception {
        for(int mode=0;mode<5;mode++) {
            Fixture f=fresh();f.initialize();f.listen(1);SpeechRecognizer r=f.recognizer();
            if(mode==0)r.listener.onResults(words("ordinary unsupported"));
            if(mode==1)r.listener.onEndOfSegmentedSession();
            if(mode==2)r.listener.onError(7);
            if(mode==3)r.listener.onError(6);
            if(mode==4)r.listener.onError(5);
            check(r.destroys==1,"ignored source/early terminal released");
            check(f.payloads("notifyError").get(0).toString().contains("error_continuous_recognition_unavailable"),"no-speech is unsupported continuous capture, not resumable silence");
            Handler.advance(120000);check(SpeechRecognizer.created.size()==1,"no recognizer restart");
        }
    }
    static void supportPreflightAndDisposal() throws Exception {
        for(int mode=0;mode<4;mode++) {
            Fixture f=fresh();f.initialize();SpeechRecognizer.supportHang=true;
            int audioBefore=android.media.AudioRecord.created.size();
            Reply reply=new Reply();f.plugin.onMethodCall(new MethodCall("listen",Map.of("captureId",1,"onDevice",true,"listenMode",1)),reply);
            check(reply.calls==0 && android.media.AudioRecord.created.size()==audioBefore,"preflight pending never acquires mic");
            SpeechRecognizer r=f.recognizer();
            if(mode==0)Handler.advance(2000);
            if(mode==1)f.call("cancel",Map.of());
            if(mode==2)f.call("stop",Map.of());
            if(mode==3)f.plugin.onDetachedFromEngine(new io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding(new Context(),null,null,null,null,null,null));
            Handler.advance(0);
            check(reply.calls==1 && Boolean.FALSE.equals(reply.value),"pending start resolved false once mode="+mode+" calls="+reply.calls);
            check(r.destroys==1,"pending capture released");
            int audioAfter=android.media.AudioRecord.created.size();
            r.supportCallback.onSupportResult(new android.speech.RecognitionSupport());
            r.supportCallback.onError(5);
            Handler.advance(2000);check(reply.calls==1,"old timeout/support callbacks cannot complete twice");
            check(audioAfter==android.media.AudioRecord.created.size(),"stale support callback cannot acquire mic");
        }
        Fixture f=fresh();f.initialize();f.listen(1);SpeechRecognizer r=f.recognizer();
        f.plugin.onDetachedFromEngine(new io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding(new Context(),null,null,null,null,null,null));
        check(r.destroys==1,"active engine detach releases");
    }
    static void activityDetachReleases() throws Exception {
        for(boolean config:new boolean[]{false,true}) {
            Fixture f=fresh();f.initialize();f.listen(1);SpeechRecognizer r=f.recognizer();
            var reader=(android.os.ParcelFileDescriptor)r.intent.extras.get("android.speech.extra.AUDIO_SOURCE");
            if(config)f.plugin.onDetachedFromActivityForConfigChanges();else f.plugin.onDetachedFromActivity();
            check(reader.closed && r.destroys==1,"activity/config detach releases source and recognizer");
            int size=f.channel.events.size();r.listener.onSegmentResults(words("detached"));
            check(f.channel.events.size()==size,"detached callback rejected");
        }
    }
    static void synchronousStartCallbacks() throws Exception {
        for(boolean error:new boolean[]{false,true}) {
            Fixture f=fresh();f.initialize();
            SpeechRecognizer.endOnStart=!error;SpeechRecognizer.errorOnStart=error;
            Reply reply=f.listen(1);SpeechRecognizer r=f.recognizer();
            check(Boolean.valueOf(!error).equals(reply.value),"synchronous start result matches lifecycle");
            if(error)check(!f.status("listening") && r.destroys==1,"startup failure cannot resurrect Listening");
            else {
                Handler.advance(120000);check(r.destroys==0,"synchronous phrase boundary starts no watchdog");
                f.call("cancel",Map.of());
            }
        }
    }
    static void pcmPipeAndRelease() throws Exception {
        Fixture f=fresh();android.system.Os.written.reset();android.system.Os.again=2;
        f.initialize();f.listen(1);
        long until=System.currentTimeMillis()+2000;
        while(android.system.Os.written.size()<8 && System.currentTimeMillis()<until)Thread.sleep(5);
        check(Arrays.equals(android.system.Os.written.toByteArray(),new byte[]{0,1,2,3,4,5,6,7}),"partial PCM writes and EAGAIN preserve exact bytes");
        var audio=android.media.AudioRecord.created.get(android.media.AudioRecord.created.size()-1);
        f.call("cancel",Map.of());until=System.currentTimeMillis()+2000;
        while(!audio.released && System.currentTimeMillis()<until)Thread.sleep(5);
        check(audio.released && audio.stopped,"cancel releases AudioRecord");
        android.system.Os.blocked=true;f.listen(2);audio=android.media.AudioRecord.created.get(android.media.AudioRecord.created.size()-1);
        f.call("cancel",Map.of());until=System.currentTimeMillis()+2000;
        while(!audio.released && System.currentTimeMillis()<until)Thread.sleep(5);
        check(audio.released,"non-reading engine cannot retain capture thread");android.system.Os.blocked=false;
        android.media.AudioRecord.failRead=true;f.listen(3);until=System.currentTimeMillis()+2000;
        while(!android.media.AudioRecord.created.get(android.media.AudioRecord.created.size()-1).released && System.currentTimeMillis()<until)Thread.sleep(5);
        Handler.advance(0);check(f.recognizer().destroys==1,"read failure releases engine");android.media.AudioRecord.failRead=false;
        synchronized(android.os.ParcelFileDescriptor.opened){for(var fd:android.os.ParcelFileDescriptor.opened)check(fd.closed,"all local pipe descriptors closed");}
    }
    static void localesAndPermission() throws Exception {
        for(int mode=0;mode<4;mode++) {
            Fixture f=fresh(); f.initialize();SpeechRecognizer.available=mode!=0;
            SpeechRecognizer.supportError=mode==1;SpeechRecognizer.supportHang=mode==2;
            Reply reply=new Reply();f.plugin.onMethodCall(new MethodCall("locales",Map.of()),reply);Handler.advance(2000);
            check(reply.calls==1,"locales responds once");
            check(((List<?>)reply.value).size()==(mode==3?1:0),"only installed local languages");
        }
        Fixture f=fresh();ContextCompat.granted=false;f.set("currentActivity",new android.app.Activity());
        Reply reply=new Reply();f.plugin.onMethodCall(new MethodCall("initialize",Map.of("noBluetooth",true)),reply);Handler.advance(0);
        check(reply.calls==0,"permission waits honestly");
        check(Arrays.equals(androidx.core.app.ActivityCompat.requested,new String[]{"android.permission.RECORD_AUDIO"}),"only mic permission");
        f.plugin.onDetachedFromEngine(new io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding(new Context(),null,null,null,null,null,null));Handler.advance(0);
        check(reply.calls==1 && Boolean.FALSE.equals(reply.value),"detach resolves pending permission");
        f.plugin.onRequestPermissionsResult(28521,new String[]{"android.permission.RECORD_AUDIO"},new int[]{0});Handler.advance(0);
        check(reply.calls==1,"late permission callback cannot double complete");
    }
    public static void main(String[] args) throws Exception {
        privacyAndCapability();finalAndGeneration();continuousCaptureAndStop();ignoredSourceFailsWithoutRestart();supportPreflightAndDisposal();activityDetachReleases();synchronousStartCallbacks();pcmPipeAndRelease();localesAndPermission();
        System.out.println("PASS actual SpeechToTextPlugin JVM lifecycle: "+assertions+" assertions (Android/Flutter doubles; NOT device/acoustic proof)");
    }
}
