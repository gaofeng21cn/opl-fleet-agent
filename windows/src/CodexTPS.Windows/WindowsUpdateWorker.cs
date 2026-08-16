using System.Diagnostics;
using System.Text.Json;

namespace CodexTPS.WindowsApp;

internal sealed class UpdateWorkerRequest
{
    public int ParentProcessId { get; init; }

    public string CurrentExecutablePath { get; init; } = string.Empty;

    public string InstallDirectory { get; init; } = string.Empty;

    public string InstallerPath { get; init; } = string.Empty;

    public string ExpectedSha256 { get; init; } = string.Empty;

    public string ExpectedVersion { get; init; } = string.Empty;

    public string ResultPath { get; init; } = string.Empty;

    public string StagingDirectory { get; init; } = string.Empty;

    public void Save(string path)
    {
        var temporaryPath = path + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(this));
        File.Move(temporaryPath, path, overwrite: true);
    }

    public static UpdateWorkerRequest Load(string path) =>
        JsonSerializer.Deserialize<UpdateWorkerRequest>(File.ReadAllText(path))
        ?? throw new InvalidDataException("更新请求无效。");
}

internal sealed class UpdateResult
{
    public bool Success { get; init; }

    public string Version { get; init; } = string.Empty;

    public string? Error { get; init; }

    public string? StagingDirectory { get; init; }
}

internal static class UpdateResultStore
{
    public static string DefaultPath => WindowsProductIdentity.DefaultUpdateResultPath;

    public static void Write(string path, UpdateResult result)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("更新结果目录无效。");
        Directory.CreateDirectory(directory);
        var temporaryPath = path + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(result));
        File.Move(temporaryPath, path, overwrite: true);
    }

    public static UpdateResult? ReadAndDelete(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            var result = JsonSerializer.Deserialize<UpdateResult>(File.ReadAllText(path));
            File.Delete(path);
            return result;
        }
        catch
        {
            return null;
        }
    }
}

internal static class WindowsUpdateWorker
{
    public const string ApplyArgument = "--apply-update";

    public static bool TryRun(string[] args, out int exitCode)
    {
        if (args.Length != 2 ||
            !string.Equals(args[0], ApplyArgument, StringComparison.OrdinalIgnoreCase))
        {
            exitCode = 0;
            return false;
        }

        exitCode = Run(args[1]);
        return true;
    }

    private static int Run(string requestPath)
    {
        UpdateWorkerRequest? request = null;
        try
        {
            request = UpdateWorkerRequest.Load(requestPath);
            Validate(request);
            WaitForParent(request.ParentProcessId);
            UpdatePackageVerifier.VerifyAsync(
                    request.InstallerPath,
                    request.ExpectedSha256)
                .GetAwaiter()
                .GetResult();
            RunInstaller(request);
            VerifyInstalledVersion(request);
            UpdateResultStore.Write(request.ResultPath, new UpdateResult
            {
                Success = true,
                Version = request.ExpectedVersion,
                StagingDirectory = request.StagingDirectory,
            });
            LaunchAndVerify(request.CurrentExecutablePath);
            return 0;
        }
        catch (Exception error)
        {
            if (request is not null)
            {
                TryWriteFailure(request, error);
                if (TryRelaunchCurrentVersion(request.CurrentExecutablePath))
                {
                    return 1;
                }
            }

            MessageBox.Show(
                $"OPL Fleet Agent 更新失败，且无法自动恢复启动。\n\n{error.Message}",
                "OPL Fleet Agent 更新失败",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 2;
        }
    }

    private static void Validate(UpdateWorkerRequest request)
    {
        if (request.ParentProcessId <= 0 ||
            !Path.IsPathFullyQualified(request.CurrentExecutablePath) ||
            !Path.IsPathFullyQualified(request.InstallDirectory) ||
            !Path.IsPathFullyQualified(request.InstallerPath) ||
            !Path.IsPathFullyQualified(request.ResultPath) ||
            !Path.IsPathFullyQualified(request.StagingDirectory) ||
            !SemanticVersion.TryParse(request.ExpectedVersion, out _) ||
            request.ExpectedSha256.Length != 64 ||
            !request.ExpectedSha256.All(Uri.IsHexDigit) ||
            !File.Exists(request.InstallerPath))
        {
            throw new InvalidDataException("更新请求无效。");
        }

        var currentPath = Path.GetFullPath(request.CurrentExecutablePath);
        var canonicalPath = Path.GetFullPath(
            WindowsProductIdentity.CanonicalExecutablePath(request.InstallDirectory));
        if (!string.Equals(currentPath, canonicalPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("更新目标与当前安装目录不一致。");
        }
    }

    private static void WaitForParent(int parentProcessId)
    {
        try
        {
            using var parent = Process.GetProcessById(parentProcessId);
            if (!parent.WaitForExit((int)TimeSpan.FromSeconds(30).TotalMilliseconds))
            {
                throw new TimeoutException("旧版本未能在 30 秒内退出。");
            }
        }
        catch (ArgumentException)
        {
            // The parent exited before the helper attached.
        }
    }

    private static void RunInstaller(UpdateWorkerRequest request)
    {
        var logPath = Path.Combine(request.StagingDirectory, "installer.log");
        var startInfo = new ProcessStartInfo(request.InstallerPath)
        {
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add("/VERYSILENT");
        startInfo.ArgumentList.Add("/SUPPRESSMSGBOXES");
        startInfo.ArgumentList.Add("/NORESTART");
        startInfo.ArgumentList.Add($"/DIR={request.InstallDirectory}");
        startInfo.ArgumentList.Add($"/LOG={logPath}");

        using var installer = Process.Start(startInfo)
            ?? throw new InvalidOperationException("无法启动 Windows 安装包。");
        installer.WaitForExit();
        if (installer.ExitCode != 0)
        {
            throw new InvalidOperationException($"安装包退出代码为 {installer.ExitCode}。");
        }
    }

    private static void VerifyInstalledVersion(UpdateWorkerRequest request)
    {
        if (!File.Exists(request.CurrentExecutablePath))
        {
            throw new FileNotFoundException("安装后找不到 OPL Fleet Agent 可执行文件。");
        }

        var productVersion = FileVersionInfo
            .GetVersionInfo(request.CurrentExecutablePath)
            .ProductVersion;
        if (productVersion is null ||
            !productVersion.StartsWith(request.ExpectedVersion, StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"安装后版本不匹配：预期 {request.ExpectedVersion}，实际 {productVersion ?? "未知"}。");
        }
    }

    private static void LaunchAndVerify(string executablePath)
    {
        using var process = Process.Start(new ProcessStartInfo(executablePath)
        {
            UseShellExecute = true,
            ArgumentList = { "--background" },
        }) ?? throw new InvalidOperationException("无法重新启动 OPL Fleet Agent。");
        if (process.WaitForExit((int)TimeSpan.FromSeconds(2).TotalMilliseconds))
        {
            throw new InvalidOperationException(
                $"新版本启动后过早退出，退出代码为 {process.ExitCode}。");
        }
    }

    private static void TryWriteFailure(UpdateWorkerRequest request, Exception error)
    {
        try
        {
            UpdateResultStore.Write(request.ResultPath, new UpdateResult
            {
                Success = false,
                Version = request.ExpectedVersion,
                Error = $"更新失败，当前版本已恢复运行：{error.Message}",
                StagingDirectory = request.StagingDirectory,
            });
        }
        catch
        {
            // Relaunch is still attempted when the receipt cannot be written.
        }
    }

    private static bool TryRelaunchCurrentVersion(string executablePath)
    {
        try
        {
            if (!File.Exists(executablePath))
            {
                return false;
            }

            _ = Process.Start(new ProcessStartInfo(executablePath)
            {
                UseShellExecute = true,
                ArgumentList = { "--background" },
            });
            return true;
        }
        catch
        {
            return false;
        }
    }
}
