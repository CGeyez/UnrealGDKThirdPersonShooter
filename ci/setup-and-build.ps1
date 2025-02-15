param(
  [string] $game_home = (get-item "$($PSScriptRoot)").parent.FullName, ## The root of the ThirdPersonShooter repo
  [string] $gdk_repo = "git@github.com:spatialos/UnrealGDK.git",
  [string] $gcs_publish_bucket = "io-internal-infra-unreal-artifacts-production/UnrealEngine",
  [string] $gdk_branch_name = "master",
  [string] $deployment_launch_configuration = "one_worker_test.json",
  [string] $deployment_snapshot_path = "snapshots/TPS-Start_Small.snapshot",
  [string] $deployment_cluster_region = "eu"
)

. "$PSScriptRoot\common.ps1"

$gdk_home = "$game_home\Game\Plugins\UnrealGDK"

pushd "$game_home"
    Start-Event "clone-gdk-plugin" "build-gdk-third-person-shooter-:windows:"
        pushd "Game"
            New-Item -Name "Plugins" -ItemType Directory -Force
            pushd "Plugins"
            Start-Process -Wait -PassThru -NoNewWindow -FilePath "git" -ArgumentList @(`
                "clone", `
                "git@github.com:spatialos/UnrealGDK.git", `
                "--depth 1", `
                "-b $gdk_branch_name"
            )
            popd
        popd
    Finish-Event "clone-gdk-plugin" "build-gdk-third-person-shooter-:windows:"

    Start-Event "get-gdk-head-commit" "build-gdk-third-person-shooter-:windows:"
        pushd $gdk_home
            # Get the short commit hash of this gdk build for later use in assembly name
            $gdk_commit_hash = (git rev-parse HEAD).Substring(0,7)
            Write-Log "GDK at commit: $gdk_commit_hash on branch $gdk_branch_name"
        popd
    Finish-Event "get-gdk-head-commit" "build-gdk-third-person-shooter-:windows:"

    Start-Event "set-up-gdk-plugin" "build-gdk-third-person-shooter-:windows:"
        pushd $gdk_home
            # Set the required variables for the GDK's setup script to use
            $msbuild_exe = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\BuildTools\MSBuild\15.0\Bin\MSBuild.exe"

            # Invoke the GDK's setup script
            &"$($gdk_home)\ci\setup-gdk.ps1"
        popd
    Finish-Event "set-up-gdk-plugin" "build-gdk-third-person-shooter-:windows:"

    # Fetch the version of Unreal Engine we need from the GDK
    pushd "$($gdk_home)/ci"
        $unreal_version = Get-Content -Path "unreal-engine.version" -Raw
        Write-Log "Using Unreal Engine version: $unreal_version"
    popd

    Start-Event "download-unreal-engine" "build-gdk-third-person-shooter-:windows:"
        ## Create an UnrealEngine directory if it doesn't already exist
        New-Item -Name "UnrealEngine" -ItemType Directory -Force

        pushd "UnrealEngine"
            Write-Log "Downloading the Unreal Engine artifacts from GCS"
            $gcs_unreal_location = "$($unreal_version).zip"

            $gsu_proc = Start-Process -Wait -PassThru -NoNewWindow "gsutil" -ArgumentList @(`
                "cp", `
                "gs://$($gcs_publish_bucket)/$($gcs_unreal_location)", `
                "$($unreal_version).zip" `
            )
            if ($gsu_proc.ExitCode -ne 0) {
                Write-Log "Failed to download Engine artifacts. Error: $($gsu_proc.ExitCode)"
                Throw "Failed to download Engine artifacts"
            }

            Write-Log "Unzipping Unreal Engine"
            $zip_proc = Start-Process -Wait -PassThru -NoNewWindow "7z" -ArgumentList @(`
            "x", `
            "$($unreal_version).zip" `
            )
            if ($zip_proc.ExitCode -ne 0) {
                Write-Log "Failed to unzip Unreal Engine. Error: $($zip_proc.ExitCode)"
                Throw "Failed to unzip Unreal Engine."
            }
        popd
    Finish-Event "download-unreal-engine" "build-gdk-third-person-shooter-:windows:"

    # Allow the GDK plugin to find the engine
    $unreal_path = "$($game_home)\UnrealEngine"
    [Environment]::SetEnvironmentVariable("UNREAL_HOME", "$unreal_path", "Machine")
    $env:UNREAL_HOME = [System.Environment]::GetEnvironmentVariable("UNREAL_HOME", "Machine")

    # Set LINUX_MULTIARCH_ROOT and then reload it for this script
    $clang_path = "$($unreal_path)\ClangToolchain\"
    [Environment]::SetEnvironmentVariable("LINUX_MULTIARCH_ROOT", $clang_path, "Machine")
    $env:LINUX_MULTIARCH_ROOT = [System.Environment]::GetEnvironmentVariable("LINUX_MULTIARCH_ROOT", "Machine")

    Start-Event "install-unreal-engine-prerequisites" "build-gdk-third-person-shooter-:windows:"
        # This runs an opaque exe downloaded in the previous step that does *some stuff* that UE needs to occur.
        # Trapping error codes on this is tricky, because it doesn't always return 0 on success, and frankly, we just don't know what it _will_ return.
        Start-Process -Wait -PassThru -NoNewWindow -FilePath "$($unreal_path)\Engine\Extras\Redist\en-us\UE4PrereqSetup_x64.exe" -ArgumentList @(`
            "/quiet" `
        )
    Finish-Event "install-unreal-engine-prerequisites" "build-gdk-third-person-shooter-:windows:"

    $build_script_path = "$($gdk_home)\SpatialGDK\Build\Scripts\BuildWorker.bat"

    Start-Event "build-editor" "build-gdk-third-person-shooter-:windows:"
        # Build the project editor to allow the snapshot commandlet to run
        $build_editor_proc = Start-Process -PassThru -NoNewWindow -FilePath $build_script_path -ArgumentList @(`
            "ThirdPersonShooterEditor", `
            "Win64", `
            "Development", `
            "ThirdPersonShooter.uproject"
        )

        # Explicitly hold on to the process handle. 
        # This works around an issue whereby Wait-Process would fail to find build_editor_proc 
        $build_editor_handle = $build_editor_proc.Handle

        Wait-Process -Id (Get-Process -InputObject $build_editor_proc).id
        if ($build_editor_proc.ExitCode -ne 0) {
            Write-Log "Failed to build Win64 Development Editor. Error: $($build_editor_proc.ExitCode)"
            Throw "Failed to build Win64 Development Editor"
        }
    Finish-Event "build-editor" "build-gdk-third-person-shooter-:windows:"

    # Invoke the GDK commandlet to generate schema and snapshot. Note: this needs to be run prior to cooking 
    Start-Event "generate-schema" "build-gdk-third-person-shooter-:windows:"
        pushd "UnrealEngine/Engine/Binaries/Win64"
            Start-Process -Wait -PassThru -NoNewWindow -FilePath ((Convert-Path .) + "\UE4Editor.exe") -ArgumentList @(`
                "$($game_home)/Game/ThirdPersonShooter.uproject", `
                "-run=GenerateSchemaAndSnapshots", `
                "-MapPaths=`"/Maps/TPS-Start_Small`""
            )

            $core_gdk_schema_path = "$($gdk_home)\SpatialGDK\Extras\schema\*"
            $schema_std_lib_path = "$($gdk_home)\SpatialGDK\Binaries\ThirdParty\Improbable\Programs\schema\*"
            New-Item -Path "$($game_home)\spatial\schema\unreal" -Name "gdk" -ItemType Directory -Force
            New-Item -Path "$($game_home)\spatial" -Name "\build\dependencies\schema\standard_library" -ItemType Directory -Force
            Copy-Item "$($core_gdk_schema_path)" -Destination "$($game_home)\spatial\schema\unreal\gdk" -Force -Recurse
            Copy-Item "$($schema_std_lib_path)" -Destination "$($game_home)\spatial\build\dependencies\schema\standard_library" -Force -Recurse
        popd
    Finish-Event "generate-schema" "build-gdk-third-person-shooter-:windows:"

    Start-Event "build-win64-client" "build-gdk-third-person-shooter-:windows:"
        $build_client_proc = Start-Process -PassThru -NoNewWindow -FilePath $build_script_path -ArgumentList @(`
            "ThirdPersonShooter", `
            "Win64", `
            "Development", `
            "ThirdPersonShooter.uproject"
        )       
        $build_client_handle = $build_client_proc.Handle
        Wait-Process -Id (Get-Process -InputObject $build_client_proc).id
        if ($build_client_proc.ExitCode -ne 0) {
            Write-Log "Failed to build Win64 Development Client. Error: $($build_client_proc.ExitCode)"
            Throw "Failed to build Win64 Development Client"
        }
    Finish-Event "build-win64-client" "build-gdk-third-person-shooter-:windows:"

    Start-Event "build-linux-worker" "build-gdk-third-person-shooter-:windows:"
        $build_server_proc = Start-Process -PassThru -NoNewWindow -FilePath $build_script_path -ArgumentList @(`
            "ThirdPersonShooterServer", `
            "Linux", `
            "Development", `
            "ThirdPersonShooter.uproject"
        )       
        $build_server_handle = $build_server_proc.Handle
        Wait-Process -Id (Get-Process -InputObject $build_server_proc).id

        if ($build_server_proc.ExitCode -ne 0) {
            Write-Log "Failed to build Linux Development Server. Error: $($build_server_proc.ExitCode)"
            Throw "Failed to build Linux Development Server"
        }
    Finish-Event "build-linux-worker" "build-gdk-third-person-shooter-:windows:"

    # Deploy the project to SpatialOS
    &$PSScriptRoot"\deploy.ps1"
popd

