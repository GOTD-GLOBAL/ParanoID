# RFC-0020: shrink-only R8 pass to avoid unnecessary Firebase dependency size, not a fixed APK ceiling.
# No optimization, no renaming: our code, WebRTC (JNI) and ZXing stay verbatim; stack traces stay readable.
-dontoptimize
-dontobfuscate
-keepattributes SourceFile,LineNumberTable,*Annotation*,Signature,InnerClasses,EnclosingMethod
-keep class org.paranoid.text.** { *; }
-keep class org.webrtc.** { *; }
-keep class com.google.zxing.** { *; }
# Components we declared by hand in AndroidManifest.xml (no Gradle manifest awareness here).
-keep class com.google.firebase.provider.FirebaseInitProvider { *; }
-keep class com.google.firebase.messaging.FirebaseMessagingService { *; }
-keep class com.google.firebase.iid.FirebaseInstanceIdReceiver { *; }
-keep class com.google.firebase.components.ComponentDiscoveryService { *; }
-keep class com.google.android.datatransport.runtime.backends.TransportBackendDiscovery { *; }
-keep class com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService { *; }
-keep class com.google.android.datatransport.runtime.scheduling.jobscheduling.AlarmManagerSchedulerBroadcastReceiver { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google.android.datatransport.cct.CctBackendFactory { *; }
-dontwarn **
