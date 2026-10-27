allprojects {
    repositories {
        google()
        mavenCentral()
        // This exact WebRTC dependency is published only by JitPack. Avoid
        // querying Flutter's artifact mirror for a GitHub/JitPack coordinate.
        exclusiveContent {
            forRepository {
                maven { url = uri("https://jitpack.io") }
            }
            filter { includeModule("com.github.davidliu", "audioswitch") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
