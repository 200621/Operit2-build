group = "app.operit.folder_access"
version = "1.0"

plugins { id("com.android.library") }

android {
    namespace = "app.operit.folder_access"
    compileSdk = flutter.compileSdkVersion
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    dependencies { implementation("androidx.annotation:annotation:1.9.1") }
}
