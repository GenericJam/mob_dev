defmodule MobDev.KotlinGradlePluginTest do
  use ExUnit.Case, async: true

  alias MobDev.KotlinGradlePlugin

  @moduletag :tmp_dir

  defp project(root, files) do
    for {rel, content} <- files do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    KotlinGradlePlugin.check(root)
  end

  describe "the fix boundary" do
    test "is 2.4.20-Beta1, as OSV records it" do
      assert KotlinGradlePlugin.below_fix?("2.4.10")
      assert KotlinGradlePlugin.below_fix?("2.4.20-Alpha1")
      refute KotlinGradlePlugin.below_fix?("2.4.20-Beta1")
      refute KotlinGradlePlugin.below_fix?("2.4.20")
      refute KotlinGradlePlugin.below_fix?("1.9")
    end
  end

  describe "build scripts" do
    test "resolves an ext kotlin_version used in the classpath coordinate", %{tmp_dir: root} do
      assert [{:vulnerable, "android/build.gradle", ["1.9.22"]}] =
               project(root, %{
                 "android/build.gradle" => """
                 buildscript {
                     ext.kotlin_version = '1.9.22'
                     dependencies { classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version" }
                 }
                 """
               })
    end

    test "reads Kotlin DSL classpath, strictly blocks and plugin versions", %{tmp_dir: root} do
      findings =
        project(root, %{
          "android/build.gradle.kts" => """
          buildscript {
              dependencies {
                  classpath("org.jetbrains.kotlin:kotlin-gradle-plugin") { version { strictly("2.3.0") } }
              }
          }
          """,
          "android/settings.gradle.kts" => """
          plugins { id("org.jetbrains.kotlin.android").version("2.0.21") apply false }
          """,
          "android/app/build.gradle.kts" => """
          plugins { kotlin("android") version "1.9.0" }
          """
        })

      assert findings == [
               {:vulnerable, "android/app/build.gradle.kts", ["1.9.0"]},
               {:vulnerable, "android/build.gradle.kts", ["2.3.0"]},
               {:vulnerable, "android/settings.gradle.kts", ["2.0.21"]}
             ]
    end

    test "ignores other Kotlin plugins, comments and unresolved variables", %{tmp_dir: root} do
      assert [] =
               project(root, %{
                 "android/build.gradle" => """
                 buildscript {
                     dependencies {
                         // classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.22'
                         classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.21'
                         classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion"
                     }
                 }
                 plugins {
                     id 'org.jetbrains.kotlin.plugin.serialization' version '1.9.22' apply false
                 }
                 """
               })
    end

    test "an unresolved KGP version still counts as declared under AGP 9", %{tmp_dir: root} do
      assert [] =
               project(root, %{
                 "android/build.gradle" => """
                 buildscript {
                     dependencies {
                         classpath 'com.android.tools.build:gradle:9.3.3'
                         classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion"
                     }
                 }
                 """
               })
    end

    test "AGP 8 with no KGP declared is not reported", %{tmp_dir: root} do
      assert [] =
               project(root, %{
                 "android/build.gradle" =>
                   "buildscript { dependencies { classpath 'com.android.tools.build:gradle:8.2.0' } }"
               })
    end

    test "a plugin id with a variable version counts as declared under AGP 9", %{tmp_dir: root} do
      for plugin <- [
            ~s|id("org.jetbrains.kotlin.android") version kotlinVersion|,
            ~s|kotlin("android") version kotlinVersion|
          ] do
        assert [] =
                 project(root, %{
                   "android/build.gradle.kts" => """
                   plugins {
                       id("com.android.application") version "9.3.3" apply false
                       #{plugin} apply false
                   }
                   """
                 })
      end
    end

    test "quoted /* and // do not start comments", %{tmp_dir: root} do
      assert [{:vulnerable, "android/app/build.gradle", ["1.9.22", "2.0.0"]}] =
               project(root, %{
                 "android/app/build.gradle" => """
                 android { packaging { resources { excludes += ['META-INF/*'] } } }
                 dependencies { classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.22' }
                 def u = 'file:///tmp'; classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:2.0.0'
                 fileTree(include: '/*.jar', exclude: '**/*.so')
                 """
               })
    end

    test "parcelize and compose-compiler pins are version-checked like KGP", %{tmp_dir: root} do
      assert [{:vulnerable, "android/build.gradle", ["2.3.0", "2.0.0"]}] =
               project(root, %{
                 "android/build.gradle" => """
                 plugins { id 'org.jetbrains.kotlin.plugin.parcelize' version '2.0.0' apply false }
                 dependencies { classpath 'org.jetbrains.kotlin:compose-compiler-gradle-plugin:2.3.0' }
                 """
               })
    end

    test "reads the kotlin(\"gradle-plugin\") and Groovy map-notation classpaths", %{
      tmp_dir: root
    } do
      assert [
               {:vulnerable, "android/app/build.gradle", ["2.0.0"]},
               {:vulnerable, "android/build.gradle.kts", ["1.9.22"]}
             ] =
               project(root, %{
                 "android/build.gradle.kts" => """
                 buildscript { dependencies { classpath(kotlin("gradle-plugin", "1.9.22")) } }
                 """,
                 "android/app/build.gradle" => """
                 dependencies { classpath group: 'org.jetbrains.kotlin', name: 'kotlin-gradle-plugin', version: '2.0.0' }
                 """
               })
    end

    test "fixed kotlin(\"gradle-plugin\") and map-notation pins satisfy AGP 9", %{tmp_dir: root} do
      for kgp <- [
            ~s|classpath(kotlin("gradle-plugin", version = "2.4.21"))|,
            ~s|classpath(kotlin("gradle-plugin", version = kotlinVersion))|,
            ~s|classpath(group = "org.jetbrains.kotlin", name = "kotlin-gradle-plugin")|
          ] do
        assert [] =
                 project(root, %{
                   "android/build.gradle.kts" => """
                   buildscript {
                       dependencies {
                           classpath("com.android.tools.build:gradle:9.3.3")
                           #{kgp}
                       }
                   }
                   """
                 }),
               kgp
      end
    end

    test "kotlin(\"gradle-plugin\", <expression>) counts as declared under AGP 9", %{
      tmp_dir: root
    } do
      for kgp <- [
            ~s|classpath(kotlin("gradle-plugin", extra["kotlin_version"] as String))|,
            ~s|classpath(kotlin("gradle-plugin", version = rootProject.extra["v"] as String))|,
            ~s|classpath(kotlin("gradle-plugin", libs.versions.kotlin.get()))|
          ] do
        assert [] =
                 project(root, %{
                   "android/build.gradle.kts" => """
                   buildscript {
                       dependencies {
                           classpath("com.android.tools.build:gradle:9.3.3")
                           #{kgp}
                       }
                   }
                   """
                 }),
               kgp
      end
    end

    test "map-notation keys are read in any order", %{tmp_dir: root} do
      assert [
               {:vulnerable, "android/app/build.gradle", ["2.0.0"]},
               {:vulnerable, "android/build.gradle.kts", ["1.9.22"]}
             ] =
               project(root, %{
                 "android/build.gradle.kts" => """
                 classpath(name = "kotlin-gradle-plugin", version = "1.9.22", group = "org.jetbrains.kotlin")
                 """,
                 "android/app/build.gradle" => """
                 classpath version: '2.0.0', name: 'kotlin-gradle-plugin', group: 'org.jetbrains.kotlin'
                 """
               })

      assert [] =
               project(root, %{
                 "android/build.gradle.kts" => """
                 classpath("com.android.tools.build:gradle:9.3.3")
                 classpath(name = "kotlin-gradle-plugin", group = "org.jetbrains.kotlin")
                 """,
                 "android/app/build.gradle" => "\n"
               })
    end

    test "map notation reads through other keys between group, name and version", %{
      tmp_dir: root
    } do
      assert [{:vulnerable, "android/build.gradle.kts", ["1.9.22"]}] =
               project(root, %{
                 "android/build.gradle.kts" => """
                 classpath(group = "org.jetbrains.kotlin", classifier = "x", name = "kotlin-gradle-plugin", ext = "jar", version = "1.9.22")
                 """
               })
    end

    test "reads [plugins.<alias>] tables", %{tmp_dir: root} do
      assert [{:vulnerable, "android/gradle/libs.versions.toml", ["1.9.22"]}] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [versions]
                 kotlin = "1.9.22"

                 [plugins.kotlin-android]
                 id = "org.jetbrains.kotlin.android"
                 version.ref = "kotlin"
                 """
               })
    end
  end

  describe "version catalog" do
    test "follows version.ref from a KGP plugin or library entry", %{tmp_dir: root} do
      assert [{:vulnerable, "android/gradle/libs.versions.toml", ["1.9.22"]}] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [versions]
                 kotlin = "1.9.22"

                 [plugins]
                 kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
                 """
               })
    end

    test "reads an inline plugin version and a library string notation", %{tmp_dir: root} do
      assert [{:vulnerable, "android/gradle/libs.versions.toml", ["2.0.0", "1.9.22"]}] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [libraries]
                 kgp = "org.jetbrains.kotlin:kotlin-gradle-plugin:2.0.0"

                 [plugins]
                 kotlin-android = { id = "org.jetbrains.kotlin.android", version = "1.9.22" }
                 """
               })
    end

    test "a kotlin version key used only by other artifacts is not KGP", %{tmp_dir: root} do
      assert [] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [versions]
                 kotlin = "1.9.22"

                 [libraries]
                 kotlin-stdlib = { module = "org.jetbrains.kotlin:kotlin-stdlib", version.ref = "kotlin" }

                 [plugins]
                 serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
                 """
               })
    end

    test "AGP 9 from the catalog with no KGP anywhere is reported", %{tmp_dir: root} do
      assert [{:builtin_kotlin_unpinned, "android/gradle/libs.versions.toml", "9.3.3"}] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [versions]
                 agp = "9.3.3"

                 [plugins]
                 android-application = { id = "com.android.application", version.ref = "agp" }
                 """
               })
    end

    test "the Android Studio AGP 9 + Compose catalog is not reported", %{tmp_dir: root} do
      assert [] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [versions]
                 agp = "9.3.3"
                 kotlin = "2.4.21"

                 [plugins]
                 android-application = { id = "com.android.application", version.ref = "agp" }
                 kotlin-compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
                 """
               })
    end

    test "KGP module names are anchored", %{tmp_dir: root} do
      assert [] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [libraries]
                 api = "org.jetbrains.kotlin:kotlin-gradle-plugin-api:1.9.22"
                 bom = { module = "org.jetbrains.kotlin:kotlin-gradle-plugins-bom", version = "1.9.22" }
                 """
               })
    end

    test "gradle-api is not AGP", %{tmp_dir: root} do
      assert [] =
               project(root, %{
                 "android/gradle/libs.versions.toml" => """
                 [libraries]
                 agp-api = { module = "com.android.tools.build:gradle-api", version = "9.3.3" }
                 """
               })
    end
  end
end
