"""Build separate x86_64 native audio test APKs with the retained signer.

Requires the same explicit signing environment as build.sh. Does not install or
start anything. The production application APK never includes these fixtures.
"""
from pathlib import Path
import os,subprocess,zipfile,json,hashlib,shutil
from webrtc_dependency import prepare
ROOT=Path(__file__).resolve().parents[2]
SDK=Path(os.environ["ANDROID_SDK_ROOT"])
T=SDK/"build-tools/35.0.0"
PLATFORM=SDK/"platforms/android-35/android.jar"
D=Path(os.environ.get("PARANOID_VOICE_FIXTURE_OUT",str(ROOT/"clients/android/out/voice-media-fixture"))).resolve()
os.umask(0o077)
D.mkdir(parents=True,exist_ok=True)
P=D/"deps"
prepare(P)
keystore=Path(os.environ["PARANOID_ANDROID_KEYSTORE"])
secret=os.environ["PARANOID_ANDROID_KS_PASSWORD"]
env=os.environ.copy()
def run(cmd):
 result=subprocess.run([str(x) for x in cmd],env=env,cwd=D,capture_output=True,text=True)
 output=(result.stdout+result.stderr).replace(secret,"[REDACTED]")
 print(output,flush=True)
 if result.returncode:raise RuntimeError("Build subprocess failed: "+str(cmd[0]))
 return output
for name in ["classes","target-dex","test-dex"]:
 shutil.rmtree(D/name,ignore_errors=True)
 (D/name).mkdir()
activity=D/"VoiceMediaFixtureActivity.java"
activity.write_text("package org.paranoid.text; public final class VoiceMediaFixtureActivity extends android.app.Activity { public void onCreate(android.os.Bundle b) { super.onCreate(b); android.widget.TextView t=new android.widget.TextView(this); t.setText(\"Isolated real WebRTC audio test fixture\"); setContentView(t); } }")
engine=ROOT/"clients/android/src/org/paranoid/text/WebRtcAudioEngine.java"
fixture=ROOT/"clients/android/test/VoiceMediaInstrumentation.java"
run(["javac","--release","8","-Xlint:-options","-cp",str(PLATFORM)+":"+str(P/"webrtc-classes.jar"),"-d",D/"classes",engine,fixture,activity])
classes=list((D/"classes/org/paranoid/text").glob("*.class"))
targetclasses=[x for x in classes if not x.name.startswith("VoiceMediaInstrumentation")]
testclasses=[x for x in classes if x.name.startswith("VoiceMediaInstrumentation")]
run([T/"d8","--lib",PLATFORM,"--min-api","26","--output",D/"target-dex",*targetclasses,P/"webrtc-classes.jar"])
run([T/"d8","--lib",PLATFORM,"--classpath",D/"classes","--classpath",P/"webrtc-classes.jar","--min-api","26","--output",D/"test-dex",*testclasses])
(D/"target-manifest.xml").write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.paranoid.voicemedialab" android:versionCode="1" android:versionName="engine-fixture"><uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/><uses-permission android:name="android.permission.INTERNET"/><uses-permission android:name="android.permission.RECORD_AUDIO"/><uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/><uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/><uses-permission android:name="android.permission.WAKE_LOCK"/><application android:label="ParanoID voice engine fixture" android:allowBackup="false" android:debuggable="false"><activity android:name="org.paranoid.text.VoiceMediaFixtureActivity" android:exported="true"/></application></manifest>''')
(D/"test-manifest.xml").write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.paranoid.voicemedialab.tests"><uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/><application android:label="Isolated media instrumentation" android:allowBackup="false"/><instrumentation android:name="org.paranoid.text.VoiceMediaInstrumentation" android:targetPackage="org.paranoid.voicemedialab" android:functionalTest="true"/></manifest>''')
artifacts=[]
for kind in ["target","test"]:
 shutil.copyfile(D/(kind+"-manifest.xml"),D/"AndroidManifest.xml")
 run([T/"aapt","package","-f","-M",D/"AndroidManifest.xml","-I",PLATFORM,"-F",D/(kind+"-unsigned.apk")])
 with zipfile.ZipFile(D/(kind+"-unsigned.apk"),"a",compression=zipfile.ZIP_DEFLATED) as z:
  z.write(D/(kind+"-dex")/"classes.dex","classes.dex")
  if kind=="target":
   z.write(P/"webrtc/x86_64/libjingle_peerconnection_so.so","lib/x86_64/libjingle_peerconnection_so.so",compress_type=zipfile.ZIP_STORED)
   for f in (ROOT/"clients/android/licenses/webrtc-150.7871.01").iterdir():z.write(f,"assets/notices/"+f.name)
 run([T/"zipalign","-P","16","-f","4",D/(kind+"-unsigned.apk"),D/(kind+"-aligned.apk")])
 apk=D/(kind+".apk")
 run([T/"apksigner","sign","--ks",keystore,"--ks-pass","env:PARANOID_ANDROID_KS_PASSWORD","--key-pass","env:PARANOID_ANDROID_KS_PASSWORD","--out",apk,D/(kind+"-aligned.apk")])
 certificate=run([T/"apksigner","verify","--print-certs",apk])
 assert "82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926" in certificate, "Unexpected fixture signer"
 run([T/"zipalign","-c","-P","16","4",apk])
 artifacts.append({"kind":kind,"path":str(apk),"sha256":hashlib.sha256(apk.read_bytes()).hexdigest()})
(D/"build-result.json").write_text(json.dumps({"artifacts":artifacts,"engine_sha256":hashlib.sha256(engine.read_bytes()).hexdigest(),"fixture_sha256":hashlib.sha256(fixture.read_bytes()).hexdigest(),"boundary":"Test-only separate package, exact product engine source, same retained signer, x86_64"},indent=2))
