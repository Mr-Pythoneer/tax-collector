# Source this to build the Windows port on the Mac with the SSD toolchain.
# Example:  source windows/env.sh && dotnet build windows/TaxCore
export DOTNET_ROOT="/Volumes/ VideoGames/TaxCollector.noindex/dotnet"
export PATH="$DOTNET_ROOT:$PATH"
export DOTNET_CLI_HOME="/Volumes/ VideoGames/TaxCollector.noindex/dotnet/cli-home"
export NUGET_PACKAGES="/Volumes/ VideoGames/TaxCollector.noindex/nuget/packages"
export NUGET_HTTP_CACHE_PATH="/Volumes/ VideoGames/TaxCollector.noindex/nuget/http-cache"
export NUGET_PLUGINS_CACHE_PATH="/Volumes/ VideoGames/TaxCollector.noindex/nuget/plugins-cache"
export TC_ARTIFACTS="/Volumes/ VideoGames/TaxCollector.noindex/out"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
