#!/usr/bin/env python3
"""Independent host tools verify real signed APK continuity and freshly compiled payloads.
Does not sign, copy keys, install, publish, or claim Android runtime execution.
"""
from pathlib import Path
import argparse, base64, hashlib, json, os, re, subprocess, tempfile, zipfile
ROOT=Path(__file__).resolve().parent

def validate_previous(current, previous):
    if previous['package'] != current['package']:
        raise ValueError('--previous must use the same application package; cross-package rename is not an in-place update')
    if previous['version_code'] >= current['version_code']:
        raise ValueError('--previous must be an older version of the same application')

def main():
    p=argparse.ArgumentParser();p.add_argument('--previous',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);args=p.parse_args()
    evidence=args.evidence;evidence.mkdir(exist_ok=True,parents=True)
    sdk=Path(os.environ['ANDROID_SDK_ROOT']);tools=sdk/'build-tools/35.0.0';platform=sdk/'platforms/android-35/android.jar';apk=ROOT/'out/paranoid-text.apk'
    ndk=sdk/'ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin'
    os.environ.update(CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=str(ndk/'aarch64-linux-android26-clang'),CC_aarch64_linux_android=str(ndk/'aarch64-linux-android26-clang'),AR_aarch64_linux_android=str(ndk/'llvm-ar'),CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384')
    records=[]
    def run(name,cmd):
        result=subprocess.run(list(map(str,cmd)),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        (evidence/('inapp-update-'+name+'.log')).write_text(result.stdout)
        records.append(dict(name=name,command=list(map(str,cmd)),exit=result.returncode))
        if result.returncode:raise RuntimeError(name+' failed')
        return result.stdout
    def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
    def inspect(path,label,tmp):
        badging=run(label+'-badging',[tools/'aapt','dump','badging',path])
        signature=run(label+'-signature',[tools/'apksigner','verify','--verbose','--print-certs','--print-certs-pem',path])
        assert 'Number of signers: 1' in signature
        assert '82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926' in signature
        cert=tmp/(label+'.der');cert.write_bytes(base64.b64decode(re.search(r'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----',signature,re.S)[1]))
        pkg,version,name=re.search(r"package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'",badging).groups()
        sdkmin=int(re.search(r"sdkVersion:'([0-9]+)'",badging)[1])
        return dict(package=pkg,version_code=int(version),version_name=name,min_sdk=sdkmin,cert=str(cert),apk_sha256=sha(path),apk_size=path.stat().st_size)
    with tempfile.TemporaryDirectory(prefix='paranoid-update-payload-') as d:
        tmp=Path(d);current=inspect(apk,'current',tmp);old=inspect(args.previous,'previous',tmp)
        # Continuity is only meaningful within the current Android application.
        assert current['package']=='global.paranoid.messenger' and current['version_code']==15
        validate_previous(current,old)
        metadata={k:current[k] for k in ['package','version_code','version_name','min_sdk','apk_sha256','apk_size']};metadata.update(schema=1,abi='arm64-v8a')
        metadata_file=evidence/'inapp-update-publish-android.json';metadata_file.write_text(json.dumps(metadata,separators=(',',':'))+'\n')
        classes=tmp/'classes';classes.mkdir();dex=tmp/'dex';dex.mkdir()
        run('fresh-java',['javac','--release','8','-Xlint:-options','-encoding','UTF-8','-classpath',os.pathsep.join(map(str,[platform,ROOT/'out/deps/zxing-core-3.5.3.jar',ROOT/'out/deps/webrtc-classes.jar'])),'-d',classes,*sorted((ROOT/'src/org/paranoid/text').glob('*.java'))])
        run('fresh-dex',[tools/'d8','--lib',platform,'--min-api','26','--output',dex,*sorted((classes/'org/paranoid/text').glob('*.class')),ROOT/'out/deps/zxing-core-3.5.3.jar',ROOT/'out/deps/webrtc-classes.jar'])
        run('fresh-manifest',[tools/'aapt','package','-f','-M',ROOT/'AndroidManifest.xml','-S',ROOT/'res','-I',platform,'-F',tmp/'manifest.apk'])
        run('native-build',['cargo','build','--locked','--release','--target','aarch64-linux-android','--manifest-path',ROOT.parent/'core/Cargo.toml'])
        with zipfile.ZipFile(apk) as archive,zipfile.ZipFile(tmp/'manifest.apk') as fresh:
            payload={k:hashlib.sha256(archive.read(k)).hexdigest() for k in archive.namelist()}
            assert archive.read('classes.dex')==(dex/'classes.dex').read_bytes()
            assert archive.read('AndroidManifest.xml')==fresh.read('AndroidManifest.xml')
            assert archive.read('lib/arm64-v8a/libparanoid_client_core.so')==(ROOT.parent/'core/target/aarch64-linux-android/release/libparanoid_client_core.so').read_bytes()
            assert archive.read('assets/THIRD_PARTY_NOTICES.txt')==(ROOT/'out/THIRD_PARTY_NOTICES.txt').read_bytes()
            assert all(not any(s in n.lower() for s in ['keystore','.key','.env','text-state','request.json','grant.json']) for n in archive.namelist())
        run('artifact-java',['javac','--release','8','-Xlint:-options','-cp',classes,'-d',tmp,ROOT/'test/UpdateArtifactSmoke.java'])
        run('actual-artifact-policy',['java','-cp',os.pathsep.join(map(str,[tmp,classes])),'org.paranoid.text.UpdateArtifactSmoke',metadata_file,apk,current['package'],str(current['version_code']),str(current['min_sdk']),current['cert'],old['package'],str(old['version_code']),old['cert']])
        run('manifest',[tools/'aapt','dump','xmltree',apk,'AndroidManifest.xml'])
        run('zipalign',[tools/'zipalign','-c','-P','16','4',apk])
        run('diff-check',['git','-C',ROOT.parent.parent,'diff','--check'])
        paths=subprocess.check_output(['git','-C',str(ROOT.parent.parent),'ls-files','--cached','--others','--exclude-standard','clients','key-protocol'],text=True).splitlines()
        source={name:sha(ROOT.parent.parent/name) for name in paths if (ROOT.parent.parent/name).is_file()}
        current.pop('cert');old.pop('cert')
        result=dict(apk_path=str(apk),current=current,previous=old,signer_sha256='82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926',payload_sha256=payload,source_sha256=source,checks=records,publish_metadata=metadata,head=subprocess.check_output(['git','-C',str(ROOT.parent.parent),'rev-parse','HEAD'],text=True).strip())
        (evidence/'inapp-update-artifact-results.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(dict(apk=str(apk),sha256=current['apk_sha256'],size=current['apk_size'],version=current['version_code'],signer=result['signer_sha256'],fresh_payload_match=True,checks=len(records)),indent=2))
if __name__=='__main__':main()
