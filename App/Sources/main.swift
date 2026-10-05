import MeterApp
import MeterUI

// Only a Release build with the release signature uses Sparkle. Debug builds and unsigned
// builds never update themselves.
#if DEBUG
    let updater: any Updater = DisabledUpdater()
#else
    let updater: any Updater =
        ReleaseSignature.isPresent() ? SparkleUpdater() : DisabledUpdater()
#endif

ClaudeMeterApplication.run(updater: updater)
