package android.speech;
import android.content.*; import java.util.*; import java.util.concurrent.Executor;
public class SpeechRecognizer {
 public static boolean available=true, failCreate=false, failStart=false, endOnStart=false, errorOnStart=false, supportHang=false, supportError=false;
 public static int genericCreates=0;
 public static final List<SpeechRecognizer> created=new ArrayList<>();
 public RecognitionListener listener; public Intent intent,supportIntent; public RecognitionSupportCallback supportCallback; public int stops,cancels,destroys;
 public static boolean isOnDeviceRecognitionAvailable(Context c){return available;}
 public static boolean isRecognitionAvailable(Context c){return true;}
 public static SpeechRecognizer createOnDeviceSpeechRecognizer(Context c){if(failCreate)throw new IllegalStateException("creation race");SpeechRecognizer r=new SpeechRecognizer();created.add(r);return r;}
 public static SpeechRecognizer createSpeechRecognizer(Context c){genericCreates++;throw new AssertionError("generic fallback");}
 public static SpeechRecognizer createSpeechRecognizer(Context c,ComponentName n){return createSpeechRecognizer(c);}
 public void setRecognitionListener(RecognitionListener l){listener=l;}
 public void startListening(Intent i){intent=i;if(failStart)throw new IllegalStateException("start race");if(endOnStart)listener.onEndOfSpeech();if(errorOnStart)listener.onError(5);}
 public void stopListening(){stops++;}
 public void cancel(){cancels++;}
 public void destroy(){destroys++;}
 public void checkRecognitionSupport(Intent i,Executor e,RecognitionSupportCallback callback){supportIntent=i;supportCallback=callback;if(!supportHang)e.execute(()->{if(supportError)callback.onError(5);else callback.onSupportResult(new RecognitionSupport());});}
 public static void reset(){available=true;failCreate=false;failStart=false;endOnStart=false;errorOnStart=false;supportHang=false;supportError=false;genericCreates=0;created.clear();}
}
