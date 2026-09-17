"""RFC-0020: exact Firebase Messaging dependency closure for the manual javac/d8 build.

No Gradle. Every artifact (AAR/JAR) is pinned by SHA256 and size, downloaded once,
and re-extracted every build so a modified cache never substitutes for the verified
archive. Only classes.jar, res/ and the library package name are taken from each AAR;
proguard/lint/native payloads are ignored (none of these AARs ship JNI).

Closure resolved 2026-09-12 from firebase-messaging 24.1.2 (highest version wins,
legacy com.android.support/android.arch aliases dropped in favour of androidx).
"""
import hashlib
import io
import re
from pathlib import Path
import urllib.request
import zipfile

SOURCES = {
    'google': 'https://dl.google.com/dl/android/maven2/',
    'central': 'https://repo.maven.apache.org/maven2/',
}
ARTIFACTS = (
    ('activity-1.0.0.aar', 'google', 'androidx/activity/activity/1.0.0/activity-1.0.0.aar',
     'd1bc9842455c2e534415d88c44df4d52413b478db9093a1ba36324f705f44c3d', 13617),
    ('annotation-1.5.0.jar', 'google', 'androidx/annotation/annotation/1.5.0/annotation-1.5.0.jar',
     '261fb7c0210858500bab66d34354972a75166ab4182add283780b05513d6ec4a', 53348),
    ('core-common-2.1.0.jar', 'google', 'androidx/arch/core/core-common/2.1.0/core-common-2.1.0.jar',
     'fe1237bf029d063e7f29fe39aeaf73ef74c8b0a3658486fc29d3c54326653889', 11257),
    ('core-runtime-2.0.0.aar', 'google', 'androidx/arch/core/core-runtime/2.0.0/core-runtime-2.0.0.aar',
     '87e65fc767c712b437649c7cee2431ebb4bed6daef82e501d4125b3ed3f65f8e', 5475),
    ('asynclayoutinflater-1.0.0.aar', 'google', 'androidx/asynclayoutinflater/asynclayoutinflater/1.0.0/asynclayoutinflater-1.0.0.aar',
     'f7eab60c57addd94bb06275832fe7600611beaaae1a1ec597c231956faf96c8b', 7826),
    ('collection-1.1.0.jar', 'google', 'androidx/collection/collection/1.1.0/collection-1.1.0.jar',
     '632a0e5407461de774409352940e292a291037724207a787820c77daf7d33b72', 42953),
    ('concurrent-futures-1.1.0.jar', 'google', 'androidx/concurrent/concurrent-futures/1.1.0/concurrent-futures-1.1.0.jar',
     '0ce067c514a0d1049d1bebdf709e344ed3266fe9744275682937cdcb13334e9e', 25987),
    ('coordinatorlayout-1.0.0.aar', 'google', 'androidx/coordinatorlayout/coordinatorlayout/1.0.0/coordinatorlayout-1.0.0.aar',
     'e508c695489493374d942bf7b4ee02abf7571d25aac4c622e57d6cd5cd29eb73', 44222),
    ('core-1.2.0.aar', 'google', 'androidx/core/core/1.2.0/core-1.2.0.aar',
     '524b8b88ceb6a74a7e44e6b567a135660f211799904cb218bfee5be1166820b2', 706226),
    ('cursoradapter-1.0.0.aar', 'google', 'androidx/cursoradapter/cursoradapter/1.0.0/cursoradapter-1.0.0.aar',
     'a81c8fe78815fa47df5b749deb52727ad11f9397da58b16017f4eb2c11e28564', 10591),
    ('customview-1.0.0.aar', 'google', 'androidx/customview/customview/1.0.0/customview-1.0.0.aar',
     '20e5b8f6526a34595a604f56718da81167c0b40a7a94a57daa355663f2594df2', 33238),
    ('documentfile-1.0.0.aar', 'google', 'androidx/documentfile/documentfile/1.0.0/documentfile-1.0.0.aar',
     '865a061ef2fad16522f8433536b8d47208c46ff7c7745197dfa1eeb481869487', 11221),
    ('drawerlayout-1.0.0.aar', 'google', 'androidx/drawerlayout/drawerlayout/1.0.0/drawerlayout-1.0.0.aar',
     '9402442cdc5a43cf62fb14f8cf98c63342d4d9d9b805c8033c6cf7e802749ac1', 32470),
    ('fragment-1.1.0.aar', 'google', 'androidx/fragment/fragment/1.1.0/fragment-1.1.0.aar',
     'a14c8b8f2153f128e800fbd266a6beab1c283982a29ec570d2cc05d307d81496', 166608),
    ('interpolator-1.0.0.aar', 'google', 'androidx/interpolator/interpolator/1.0.0/interpolator-1.0.0.aar',
     '33193135a64fe21fa2c35eec6688f1a76e512606c0fc83dc1b689e37add7732a', 7669),
    ('legacy-support-core-ui-1.0.0.aar', 'google', 'androidx/legacy/legacy-support-core-ui/1.0.0/legacy-support-core-ui-1.0.0.aar',
     '0d1260c6e7e6a337f875df71b516931e703f716e90889817cd3a20fa5ac3d947', 11309),
    ('legacy-support-core-utils-1.0.0.aar', 'google', 'androidx/legacy/legacy-support-core-utils/1.0.0/legacy-support-core-utils-1.0.0.aar',
     'a7edcf01d5b52b3034073027bc4775b78a4764bb6202bb91d61c829add8dd1c7', 4104),
    ('lifecycle-common-2.1.0.jar', 'google', 'androidx/lifecycle/lifecycle-common/2.1.0/lifecycle-common-2.1.0.jar',
     '76db6be533bd730fb361c2feb12a2c26d9952824746847da82601ef81f082643', 21688),
    ('lifecycle-livedata-2.0.0.aar', 'google', 'androidx/lifecycle/lifecycle-livedata/2.0.0/lifecycle-livedata-2.0.0.aar',
     'c82609ced8c498f0a701a30fb6771bb7480860daee84d82e0a81ee86edf7ba39', 9431),
    ('lifecycle-livedata-core-2.0.0.aar', 'google', 'androidx/lifecycle/lifecycle-livedata-core/2.0.0/lifecycle-livedata-core-2.0.0.aar',
     'fde334ec7e22744c0f5bfe7caf1a84c9d717327044400577bdf9bd921ec4f7bc', 8372),
    ('lifecycle-runtime-2.1.0.aar', 'google', 'androidx/lifecycle/lifecycle-runtime/2.1.0/lifecycle-runtime-2.1.0.aar',
     'e5173897b965e870651e83d9d5af1742d3f532d58863223a390ce3a194c8312b', 9160),
    ('lifecycle-viewmodel-2.1.0.aar', 'google', 'androidx/lifecycle/lifecycle-viewmodel/2.1.0/lifecycle-viewmodel-2.1.0.aar',
     'ba55fb7ac1b2828d5327cda8acf7085d990b2b4c43ef336caa67686249b8523d', 8647),
    ('loader-1.0.0.aar', 'google', 'androidx/loader/loader/1.0.0/loader-1.0.0.aar',
     '11f735cb3b55c458d470bed9e25254375b518b4b1bad6926783a7026db0f5025', 33445),
    ('localbroadcastmanager-1.0.0.aar', 'google', 'androidx/localbroadcastmanager/localbroadcastmanager/1.0.0/localbroadcastmanager-1.0.0.aar',
     'e71c328ceef5c4a7d76f2d86df1b65d65fe2acf868b1a4efd84a3f34336186d8', 6808),
    ('print-1.0.0.aar', 'google', 'androidx/print/print/1.0.0/print-1.0.0.aar',
     '1d5c7f3135a1bba661fc373fd72e11eb0a4adbb3396787826dd8e4190d5d9edd', 15782),
    ('savedstate-1.0.0.aar', 'google', 'androidx/savedstate/savedstate/1.0.0/savedstate-1.0.0.aar',
     '2510a5619c37579c9ce1a04574faaf323cd0ffe2fc4e20fa8f8f01e5bb402e83', 9768),
    ('slidingpanelayout-1.0.0.aar', 'google', 'androidx/slidingpanelayout/slidingpanelayout/1.0.0/slidingpanelayout-1.0.0.aar',
     '76bffb7cefbf780794d8817002dad1562f3e27c0a9f746d62401c8edb30aeede', 23503),
    ('swiperefreshlayout-1.0.0.aar', 'google', 'androidx/swiperefreshlayout/swiperefreshlayout/1.0.0/swiperefreshlayout-1.0.0.aar',
     '9761b3a809c9b093fd06a3c4bbc645756dec0e95b5c9da419bc9f2a3f3026e8d', 32883),
    ('versionedparcelable-1.1.0.aar', 'google', 'androidx/versionedparcelable/versionedparcelable/1.1.0/versionedparcelable-1.1.0.aar',
     '9a1d77140ac222b7866b5054ee7d159bc1800987ed2d46dd6afdd145abb710c1', 31062),
    ('viewpager-1.0.0.aar', 'google', 'androidx/viewpager/viewpager/1.0.0/viewpager-1.0.0.aar',
     '147af4e14a1984010d8f155e5e19d781f03c1d70dfed02a8e0d18428b8fc8682', 53513),
    ('transport-api-3.1.0.aar', 'google', 'com/google/android/datatransport/transport-api/3.1.0/transport-api-3.1.0.aar',
     '7dafc39f0ea835473366acc346f7e67fc8443f4c645d999c3e987bcad6b88c7b', 8464),
    ('transport-backend-cct-3.1.9.aar', 'google', 'com/google/android/datatransport/transport-backend-cct/3.1.9/transport-backend-cct-3.1.9.aar',
     '07a32025a65b08ee7e11d14dc539a758b66713f0c1d13900a81599ceadbaf44d', 53551),
    ('transport-runtime-3.1.9.aar', 'google', 'com/google/android/datatransport/transport-runtime/3.1.9/transport-runtime-3.1.9.aar',
     '41745c5b8f427d24439015b84f651ad420718991867d2afc262c264009b802c1', 179644),
    ('play-services-base-18.1.0.aar', 'google', 'com/google/android/gms/play-services-base/18.1.0/play-services-base-18.1.0.aar',
     '4eca56ceecd4325a376cd843af56377e2376ce284d0c6f05a5d0a82f4c1bf8cd', 582829),
    ('play-services-basement-18.3.0.aar', 'google', 'com/google/android/gms/play-services-basement/18.3.0/play-services-basement-18.3.0.aar',
     '6c11ae3eb2dd7f17373f919c4c557a70e4cf891bc0c9b66926a0a6445d654352', 403997),
    ('play-services-cloud-messaging-17.2.0.aar', 'google', 'com/google/android/gms/play-services-cloud-messaging/17.2.0/play-services-cloud-messaging-17.2.0.aar',
     '27255e7fe9706483816b158db25cf319f6a26a0566feff41597ce8807a350e37', 103747),
    ('play-services-stats-17.0.2.aar', 'google', 'com/google/android/gms/play-services-stats/17.0.2/play-services-stats-17.0.2.aar',
     'dd4314a53f49a378ec146103d36232b96c75454d29526336ccbdf132941764d3', 14753),
    ('play-services-tasks-18.1.0.aar', 'google', 'com/google/android/gms/play-services-tasks/18.1.0/play-services-tasks-18.1.0.aar',
     'd60575eae39350e6234858bc9d7d775375707ae82a684e6caf7f3e41a12e25a2', 96788),
    ('error_prone_annotations-2.26.0.jar', 'central', 'com/google/errorprone/error_prone_annotations/2.26.0/error_prone_annotations-2.26.0.jar',
     '53cdfc0beb2d766fe03b78f0b11d020554cd419879d20380c38fa1dcf2ba1b50', 18988),
    ('firebase-annotations-16.2.0.jar', 'google', 'com/google/firebase/firebase-annotations/16.2.0/firebase-annotations-16.2.0.jar',
     '46f6d5dfdd2ccf3c40de897a14bd9779314c3319f44bfd31e7e0a20d935a5e3e', 3769),
    ('firebase-common-21.0.0.aar', 'google', 'com/google/firebase/firebase-common/21.0.0/firebase-common-21.0.0.aar',
     '379287d7171371512493681b398e78c341b333cf974ee81a18b1d56e7c2e385d', 116075),
    ('firebase-common-ktx-21.0.0.aar', 'google', 'com/google/firebase/firebase-common-ktx/21.0.0/firebase-common-ktx-21.0.0.aar',
     '25fc80c9bb9ecb1672908718c294afcc4ac1e47473677be060c795e04f120066', 3177),
    ('firebase-components-18.0.0.aar', 'google', 'com/google/firebase/firebase-components/18.0.0/firebase-components-18.0.0.aar',
     'c7c48a3a80f44a499ebd6473bcfc7dd5a45ef523fabe2414a62515ff3c640972', 45720),
    ('firebase-datatransport-18.2.0.aar', 'google', 'com/google/firebase/firebase-datatransport/18.2.0/firebase-datatransport-18.2.0.aar',
     'b2b28f6ba173f5e0c4fe3d36a2d7ee5239c7acbf4143b549ecf031a3485b35bb', 5825),
    ('firebase-encoders-17.0.0.jar', 'google', 'com/google/firebase/firebase-encoders/17.0.0/firebase-encoders-17.0.0.jar',
     '282a5a703f9b7eb56508dde97ea918e95d73318b157050f457f7a86dca750150', 17847),
    ('firebase-encoders-json-18.0.0.aar', 'google', 'com/google/firebase/firebase-encoders-json/18.0.0/firebase-encoders-json-18.0.0.aar',
     '80aece7e1ef58957ca2fc1957bc9208ec92a3a9528201331d3c63e3182570f97', 9223),
    ('firebase-encoders-proto-16.0.0.jar', 'google', 'com/google/firebase/firebase-encoders-proto/16.0.0/firebase-encoders-proto-16.0.0.jar',
     '293db96a0d1d43f033167881b638d8fde844e4e5495f5101cf52295765295e0e', 38980),
    ('firebase-iid-interop-17.1.0.aar', 'google', 'com/google/firebase/firebase-iid-interop/17.1.0/firebase-iid-interop-17.1.0.aar',
     '0b7c3721c84b62e70415307239ed4a7f998989084bf2833f90b9f5bea3095a05', 8426),
    ('firebase-installations-17.2.0.aar', 'google', 'com/google/firebase/firebase-installations/17.2.0/firebase-installations-17.2.0.aar',
     'de011e6a3b7961de638f172f2cb66ba304eaa989662a9e2b0f48dff774ccc166', 58525),
    ('firebase-installations-interop-17.1.1.aar', 'google', 'com/google/firebase/firebase-installations-interop/17.1.1/firebase-installations-interop-17.1.1.aar',
     'fac650680f7921f4ab92f0bb21a09234b12cdaefab2cf70188281d7ea52b8dad', 8166),
    ('firebase-measurement-connector-19.0.0.aar', 'google', 'com/google/firebase/firebase-measurement-connector/19.0.0/firebase-measurement-connector-19.0.0.aar',
     'dba74d6bf94647ee397bf7afb2ab07f6fe8d13157e56785fa540a2a13ed82c99', 10625),
    ('firebase-messaging-24.1.2.aar', 'google', 'com/google/firebase/firebase-messaging/24.1.2/firebase-messaging-24.1.2.aar',
     '8d587f7f3724d5c3c912a95eecf72b01725462317cd3156dd222301956947661', 148741),
    ('listenablefuture-1.0.jar', 'central', 'com/google/guava/listenablefuture/1.0/listenablefuture-1.0.jar',
     'e4ad7607e5c0477c6f890ef26a49cb8d1bb4dffb650bab4502afee64644e3069', 3149),
    ('javax.inject-1.jar', 'central', 'javax/inject/javax.inject/1/javax.inject-1.jar',
     '91c77044a50c481636c32d916fd89c9118a72195390452c81065080f957de7ff', 2497),
    ('kotlin-stdlib-1.8.22.jar', 'central', 'org/jetbrains/kotlin/kotlin-stdlib/1.8.22/kotlin-stdlib-1.8.22.jar',
     '03a5c3965cc37051128e64e46748e394b6bd4c97fa81c6de6fc72bfd44e3421b', 1670469),
    ('kotlin-stdlib-common-1.8.22.jar', 'central', 'org/jetbrains/kotlin/kotlin-stdlib-common/1.8.22/kotlin-stdlib-common-1.8.22.jar',
     'd0c2365e2437ef70f34586d50f055743f79716bcfe65e4bc7239cdd2669ef7c5', 221491),
    ('kotlin-stdlib-jdk7-1.8.22.jar', 'central', 'org/jetbrains/kotlin/kotlin-stdlib-jdk7/1.8.22/kotlin-stdlib-jdk7-1.8.22.jar',
     '055f5cb24287fa106100995a7b47ab92126b81e832e875f5fa2cf0bd55693d0b', 963),
    ('kotlin-stdlib-jdk8-1.8.22.jar', 'central', 'org/jetbrains/kotlin/kotlin-stdlib-jdk8/1.8.22/kotlin-stdlib-jdk8-1.8.22.jar',
     '4198b0eaf090a4f25b6f7e5a59581f4314ba8c9f6cd1d13ee9d348e65ed8f707', 969),
    ('kotlinx-coroutines-core-jvm-1.6.4.jar', 'central', 'org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.6.4/kotlinx-coroutines-core-jvm-1.6.4.jar',
     'c24c8bb27bb320c4a93871501a7e5e0c61607638907b197aef675513d4c820be', 1476653),
    ('kotlinx-coroutines-play-services-1.6.4.jar', 'central', 'org/jetbrains/kotlinx/kotlinx-coroutines-play-services/1.6.4/kotlinx-coroutines-play-services-1.6.4.jar',
     '4ee3784c3465caab86adcc4f93956d56ea662aac82e5c2c83ca3c1f0415fe397', 13030),
    ('annotations-13.0.jar', 'central', 'org/jetbrains/annotations/13.0/annotations-13.0.jar',
     'ace2a10dc8e2d5fd34925ecac03e4988b2c0f851650c94b8cef49ba1bd111478', 17536),
)
MAX_BYTES = 4 * 1024 * 1024


def fetch(source, path, size):
    with urllib.request.urlopen(SOURCES[source] + path, timeout=120) as response:
        return response.read(size + 1)


def prepare(dest):
    dest = Path(dest)
    archives = dest / 'fcm-archives'
    jars = dest / 'fcm-jars'
    res = dest / 'fcm-res'
    for directory in (archives, jars, res):
        directory.mkdir(parents=True, exist_ok=True)
    for stale in list(jars.glob('*.jar')):
        stale.unlink()
    for stale in list(res.glob('*')):
        if stale.is_dir():
            for path in sorted(stale.rglob('*'), reverse=True):
                path.rmdir() if path.is_dir() else path.unlink()
            stale.rmdir()
    packages = []
    for name, source, path, expected, size in ARTIFACTS:
        if size > MAX_BYTES:
            raise RuntimeError('Firebase dependency integrity: unexpected size ' + name)
        archive = archives / name
        if archive.exists():
            data = archive.read_bytes()
        else:
            data = fetch(source, path, size)
        if len(data) != size or hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError('Firebase dependency integrity: wrong SHA256 ' + name)
        if not archive.exists():
            archive.write_bytes(data)
        stem = name.rsplit('.', 1)[0]
        if name.endswith('.jar'):
            (jars / name).write_bytes(data)
            continue
        with zipfile.ZipFile(io.BytesIO(data)) as aar:
            names = set(aar.namelist())
            if any(entry.startswith('jni/') for entry in names):
                raise RuntimeError('Firebase dependency integrity: unexpected native payload ' + name)
            (jars / (stem + '.jar')).write_bytes(aar.read('classes.jar'))
            manifest = aar.read('AndroidManifest.xml').decode('utf-8')
            package = re.search(r'package="([A-Za-z0-9_.]+)"', manifest)
            if package is None:
                raise RuntimeError('Firebase dependency integrity: manifest package ' + name)
            entries = sorted(entry for entry in names if entry.startswith('res/') and not entry.endswith('/'))
            if entries:
                for entry in entries:
                    if '..' in entry.split('/'):
                        raise RuntimeError('Firebase dependency integrity: path ' + name)
                    target = res / stem / entry[len('res/'):]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(aar.read(entry))
                packages.append(package.group(1))
    # Libraries whose bytecode references their own R class need that R generated by aapt.
    (dest / 'fcm-packages.txt').write_text('\n'.join(sorted(set(packages))) + '\n')
    print('Verified Firebase Messaging closure: %d artifacts, %d resource packages' % (len(ARTIFACTS), len(set(packages))))


if __name__ == '__main__':
    prepare(Path(__file__).resolve().parent / 'out/deps')
