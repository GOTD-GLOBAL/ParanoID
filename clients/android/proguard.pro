# RFC-0020: shrink-only R8 pass applied to the Firebase Messaging closure ONLY.
# Our code, WebRTC (JNI: native FindClass through org.webrtc.WebRtcClassLoader) and ZXing are dexed
# separately by d8 and never pass through R8 — a whole-program R8 run with keep rules still broke
# libjingle's JNI class lookup (v20–v23: SIGABRT "java_class == null in GetStaticMethodID" at
# PeerConnectionFactory.initialize, reproduced on the x86_64 emulator 2026-09-12).
-dontoptimize
-dontobfuscate
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
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
# Public API our PushService/TextEngine call (app classes are on --classpath, not in the program).
-keep class com.google.firebase.messaging.FirebaseMessaging { public *; }
-keep class com.google.firebase.messaging.RemoteMessage { public *; }
-keep class com.google.android.gms.tasks.** { public *; }
-dontwarn **
