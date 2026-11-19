[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$SkipApplications,
    [switch]$SkipProjectClone
)

$ErrorActionPreference = 'Stop'
$owner = 'LukGit036'
$backupRepo = "$owner/claude-setup"
$vaultRepo = "$owner/segunda-mente"
$projectRepo = "$owner/Underworld-Workspace"
$wingetIds = @(
    'Microsoft.VisualStudioCode', 'Git.Git', 'GitHub.cli', 'OpenJS.NodeJS.LTS',
    'Python.Python.3.14', 'astral-sh.uv', 'Microsoft.PowerShell', 'Gyan.FFmpeg',
    'Streamlink.Streamlink', 'Obsidian.Obsidian', 'Google.Antigravity',
    'Google.AntigravityCLI', 'Anthropic.Claude', 'Anthropic.ClaudeCode',
    'MoonshotAI.KimiCodeCLI'
)
$npmPackages = @('@anthropic-ai/claude-code', '@google/gemini-cli', '@openai/codex')

function Write-Step([string]$message) { Write-Host "`n=== $message ===" -ForegroundColor Cyan }
function Refresh-UserPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @($machine, $user, $env:Path) | Where-Object { $_ }
    $env:Path = $paths -join ';'
}
function Invoke-External([string]$exe, [string[]]$arguments, [string]$label) {
    $command = Get-Command $exe -ErrorAction SilentlyContinue
    if (-not $command) { Write-Warning "${label}: comando '$exe' não encontrado."; $script:failures.Add($label); return $false }
    & $command.Source @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning "$label terminou com código $LASTEXITCODE."; $script:failures.Add($label); return $false }
    return $true
}
function Get-SafeTarget([string]$desired) {
    if (-not (Test-Path -LiteralPath $desired)) { return $desired }
    if (Test-Path -LiteralPath (Join-Path $desired '.git')) { return $desired }
    $children = @(Get-ChildItem -LiteralPath $desired -Force -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) { return $desired }
    return "$desired-restaurado-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
function Install-PrivateRepo([string]$repo, [string]$desired) {
    $target = Get-SafeTarget $desired
    if (Test-Path -LiteralPath (Join-Path $target '.git')) {
        $remote = & git -C $target remote get-url origin 2>$null
        $expectedRemote = 'github\.com[/:]' + [regex]::Escape($repo) + '(?:\.git)?$'
        if ($LASTEXITCODE -ne 0 -or $remote -notmatch $expectedRemote) {
            $target = "$desired-restaurado-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Write-Host "O destino já contém outro repositório; vou preservar e clonar $repo em $target"
        } else {
            Write-Host "Atualizando repositório existente: $target"
            if (-not (Invoke-External 'git' @('-C', $target, 'pull', '--ff-only') "Atualização de $repo")) {
                throw "Não atualizei $target porque há divergências locais. Seus arquivos foram preservados."
            }
            return $target
        }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    if (-not (Invoke-External 'gh' @('repo', 'clone', $repo, $target) "Clone de $repo")) { throw "Não consegui baixar o repositório privado $repo. Confira o acesso no GitHub." }
    return $target
}
function Copy-Snapshot([string]$source, [string]$desired) {
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { Write-Warning "Snapshot não encontrado: $source"; $script:failures.Add("Snapshot $source"); return $desired }
    $target = $desired
    if (Test-Path -LiteralPath $target) {
        $children = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) { Write-Host "Mantive o cofre Aincrad existente sem sobrescrever arquivos: $target"; return $target }
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem -LiteralPath $source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force }
    Write-Host "Snapshot restaurado: $target"
    return $target
}
function Update-JsonMcpConfig([string]$file, [hashtable]$servers) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $file) {
        $original = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
        try { $config = $original | ConvertFrom-Json } catch { throw "JSON inválido em $file; não alterei o arquivo. Faça backup e corrija-o antes de continuar." }
    } else { $original = ''; $config = [pscustomobject]@{} }
    if (-not $config.PSObject.Properties['mcpServers']) { $config | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) }
    foreach ($requestedName in $servers.Keys) {
        $entry = $servers[$requestedName]
        $existingProperty = $config.mcpServers.PSObject.Properties[$requestedName]
        if ($existingProperty) {
            if (($existingProperty.Value | ConvertTo-Json -Depth 20 -Compress) -eq ($entry | ConvertTo-Json -Depth 20 -Compress)) { continue }
            $existingProperty.Value = $entry
        } else {
            $config.mcpServers | Add-Member -NotePropertyName $requestedName -NotePropertyValue $entry
        }
    }
    if ($original -and ((ConvertFrom-Json $original | ConvertTo-Json -Depth 60 -Compress) -eq ($config | ConvertTo-Json -Depth 60 -Compress))) { return }
    if ($original) { Copy-Item -LiteralPath $file -Destination "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    [IO.File]::WriteAllText($file, ($config | ConvertTo-Json -Depth 60), $utf8)
    Write-Host "MCPs restaurados em $file"
}
function ConvertTo-TomlString([string]$value) {
    return '"' + $value.Replace('\', '\\').Replace('"', '\"') + '"'
}
function Add-CodexMcp([string]$file, [string]$name, [string]$vault) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $original = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) } else { '' }
    $block = "[mcp_servers.$name]`ncommand = 'npx'`nargs = ['-y', '@bitbonsai/mcpvault@0.18.4', $(ConvertTo-TomlString $vault)]`n"
    $pattern = "(?ms)^\[mcp_servers\.$([regex]::Escape($name))\]\r?\n.*?(?=^\[|\z)"
    $match = [regex]::Match($original, $pattern)
    if ($match.Success) {
        if ($match.Value.Trim() -eq $block.Trim()) { return }
        $updated = $original.Substring(0, $match.Index) + $block + $original.Substring($match.Index + $match.Length)
    } else { $updated = $original.TrimEnd() + "`n`n" + $block }
    if ($original) { Copy-Item -LiteralPath $file -Destination "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    [IO.File]::WriteAllText($file, $updated, $utf8)
    Write-Host "MCP $name configurado no Codex."
}
function Register-ObsidianVaults([string]$primaryVault, [string]$secondaryVault) {
    $file = Join-Path $env:APPDATA 'obsidian\obsidian.json'
    $utf8 = New-Object Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $file) {
        $original = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
        try { $config = $original | ConvertFrom-Json } catch { throw "JSON inválido em $file; não alterei o arquivo." }
    } else { $original = ''; $config = [pscustomobject]@{} }
    if (-not $config.PSObject.Properties['vaults']) { $config | Add-Member -NotePropertyName vaults -NotePropertyValue ([pscustomobject]@{}) }
    $changed = $false
    foreach ($path in @($primaryVault, $secondaryVault)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $fullPath = (Get-Item -LiteralPath $path).FullName
        $isPrimary = $fullPath -ieq $primaryVault
        $existing = $config.vaults.PSObject.Properties | Where-Object { $_.Value.path -ieq $fullPath } | Select-Object -First 1
        if ($existing) {
            if (-not $existing.Value.PSObject.Properties['open'] -or [bool]$existing.Value.open -ne $isPrimary) {
                $existing.Value | Add-Member -NotePropertyName open -NotePropertyValue $isPrimary -Force
                $changed = $true
            }
            continue
        }
        $md5 = [Security.Cryptography.MD5]::Create()
        try { $id = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath))).Replace('-', '').ToLowerInvariant() } finally { $md5.Dispose() }
        while ($config.vaults.PSObject.Properties[$id]) { $id = [Guid]::NewGuid().ToString('N') }
        $entry = [pscustomobject]@{ path = $fullPath; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); open = $isPrimary }
        $config.vaults | Add-Member -NotePropertyName $id -NotePropertyValue $entry
        $changed = $true
    }
    if (-not $changed) { Write-Host 'Vaults do Obsidian já estão registrados.'; return }
    if ($original) { Copy-Item -LiteralPath $file -Destination "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    [IO.File]::WriteAllText($file, ($config | ConvertTo-Json -Depth 60), $utf8)
    Write-Host "Vaults do Obsidian registrados em $file"
}

if ($PlanOnly) {
    Write-Host 'PLANO — nenhuma alteração será feita.' -ForegroundColor Green
    Write-Host "Aplicativos winget: $($wingetIds -join ', ')"
    Write-Host "CLIs npm: $($npmPackages -join ', ')"
    Write-Host 'Também: GitHub login, cópia privada dos cofres/automações, Graphify, ai-memory, MCPVault e configuração NVIDIA local protegida.'
    Write-Host 'A chave NVIDIA não é transferida nem incluída no GitHub; o instalador poderá pedi-la ao final.'
    return
}

$script:failures = [Collections.Generic.List[string]]::new()
if (-not $SkipApplications) {
    Write-Step 'Instalando ferramentas e aplicativos'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'O Windows Package Manager (winget) não está disponível. Instale/atualize o App Installer pela Microsoft Store e execute novamente.' }
    foreach ($id in $wingetIds) {
        Write-Host "Instalando/confirmando $id..."
        & $winget.Source install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) { Write-Warning "$id não instalou (código $LASTEXITCODE)."; $script:failures.Add("winget $id") }
    }
    Refresh-UserPath
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Step 'Instalando CLIs das IAs'
        Invoke-External 'npm' (@('install', '--global') + $npmPackages) 'CLIs Claude/Gemini/Codex' | Out-Null
    } else { Write-Warning 'Node/npm ainda não apareceu no PATH; execute novamente após reiniciar o PowerShell.'; $script:failures.Add('npm ausente após instalação do Node.js') }
    Refresh-UserPath
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Invoke-External 'uv' @('tool', 'install', '--upgrade', 'graphifyy') 'Graphify CLI' | Out-Null
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        Invoke-External 'python' @('-m', 'pip', 'install', '--user', '--upgrade', 'uv') 'uv CLI' | Out-Null
        Refresh-UserPath
        if (Get-Command uv -ErrorAction SilentlyContinue) { Invoke-External 'uv' @('tool', 'install', '--upgrade', 'graphifyy') 'Graphify CLI' | Out-Null }
    } else { $script:failures.Add('uv/Graphify — Python não encontrado') }
}

Refresh-UserPath
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) não está disponível; veja os avisos de instalação acima e rode novamente.' }
Write-Step 'Autenticando no GitHub para baixar os repositórios privados'
& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'O GitHub abrirá a autenticação pelo navegador. Entre na sua conta e autorize o acesso.'
    & gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { throw 'A autenticação no GitHub não terminou. Execute novamente após autorizar a conta.' }
}
& gh auth setup-git

$dataRoot = if (Test-Path -LiteralPath 'D:\') { 'D:\Aincrad' } else { Join-Path $HOME 'Documents\Aincrad' }
$vaultPath = Install-PrivateRepo $vaultRepo (Join-Path $HOME 'Documents\Alice Síntese')
$backupPath = Install-PrivateRepo $backupRepo (Join-Path $vaultPath 'Configuração e backup')
$snapshotPath = Copy-Snapshot (Join-Path $backupPath 'Aincrad') (Join-Path $dataRoot 'Aincrad')
Register-ObsidianVaults $vaultPath $snapshotPath

if (-not $SkipProjectClone) {
    Write-Step 'Restaurando o projeto Underworld e o grafo Graphify'
    $projectPath = Install-PrivateRepo $projectRepo (Join-Path $HOME 'Documents\Underworld\Underworld_Workspace')
    $graphSource = Join-Path $backupPath 'graphify-out'
    $graphTarget = Join-Path $projectPath 'graphify-out'
    if (Test-Path -LiteralPath $graphTarget) {
        $children = @(Get-ChildItem -LiteralPath $graphTarget -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) { Get-ChildItem -LiteralPath $graphSource -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $graphTarget -Recurse -Force } }
        else { Write-Host "Grafo já existente preservado: $graphTarget" }
    } elseif (Test-Path -LiteralPath $graphSource) {
        New-Item -ItemType Directory -Force -Path $graphTarget | Out-Null
        Get-ChildItem -LiteralPath $graphSource -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $graphTarget -Recurse -Force }
    } else { $script:failures.Add('graphify-out ausente no backup privado') }
}

[Environment]::SetEnvironmentVariable('AINCRAD_BACKUP_DIR', $backupPath, 'User')
[Environment]::SetEnvironmentVariable('AINCRAD_VAULT_PATH', $vaultPath, 'User')
$env:AINCRAD_BACKUP_DIR = $backupPath
$env:AINCRAD_VAULT_PATH = $vaultPath
Write-Step 'Restaurando skills, hooks e servidores MCP particulares'
$legacyInstaller = Join-Path $backupPath 'scripts-claude\instalar.ps1'
if (Test-Path -LiteralPath $legacyInstaller) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $legacyInstaller
    if ($LASTEXITCODE -ne 0) { $script:failures.Add('instalador de skills/MCP da conta') }
    $secondMind = Join-Path $backupPath 'scripts-claude\aplicar-segunda-mente.ps1'
    if (Test-Path -LiteralPath $secondMind) { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $secondMind; if ($LASTEXITCODE -ne 0) { $script:failures.Add('hook do cofre') } }
} else { $script:failures.Add('scripts de automação ausentes no repositório privado') }

Write-Step 'Instalando ai-memory e hooks nos agentes'
try {
    if (-not (Get-Command ai-memory -ErrorAction SilentlyContinue)) {
        $aiMemoryInstallerPath = Join-Path $env:TEMP 'aincrad-ai-memory-install.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/akitaonrails/ai-memory/releases/latest/download/install.ps1' -OutFile $aiMemoryInstallerPath -TimeoutSec 60
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $aiMemoryInstallerPath
        if ($LASTEXITCODE -ne 0) { throw "O instalador do ai-memory saiu com código $LASTEXITCODE." }
        Refresh-UserPath
    } else { Write-Host 'ai-memory já instalado; vou reutilizar a instalação local.' }
    if (Get-Command ai-memory -ErrorAction SilentlyContinue) {
        & ai-memory setup --yes --language pt-BR --agent claude-code --agent codex --agent gemini-cli --agent antigravity-cli --agent kimi-code
        if ($LASTEXITCODE -ne 0) { $script:failures.Add('ai-memory setup/hooks') }
        & ai-memory install-hooks --agent claude-code --no-capture-prompts --apply
        if ($LASTEXITCODE -ne 0) { $script:failures.Add('ai-memory hook privado para Claude Code') }
    } else { $script:failures.Add('ai-memory CLI não apareceu no PATH') }
} catch { Write-Warning "ai-memory não foi concluído: $($_.Exception.Message)"; $script:failures.Add('ai-memory') }

Write-Step 'Instalando Graphify para Claude, Codex, Gemini, Antigravity e Kimi'
foreach ($platform in @('claude', 'codex', 'gemini', 'antigravity-windows', 'kimi')) {
    $graphify = Get-Command graphify -ErrorAction SilentlyContinue
    if ($graphify) { Invoke-External $graphify.Source @('install', '--platform', $platform) "Graphify $platform" | Out-Null }
    elseif (Get-Command uvx -ErrorAction SilentlyContinue) { Invoke-External 'uvx' @('--from', 'graphifyy', 'graphify', 'install', '--platform', $platform) "Graphify $platform" | Out-Null }
    else { $script:failures.Add("Graphify $platform — CLI ausente") }
}

Write-Step 'Configurando os dois cofres como MCP nos agentes'
$servers = @{}
foreach ($item in @(@{name='segunda_mente'; path=$vaultPath}, @{name='aincrad'; path=$snapshotPath})) {
    $servers[$item.name] = @{ command = 'npx'; args = @('-y', '@bitbonsai/mcpvault@0.18.4', $item.path) }
}
$claudeConfig = Join-Path $HOME '.claude.json'
$geminiConfig = Join-Path $HOME '.gemini\settings.json'
$antigravityConfig = Join-Path $HOME '.gemini\config\mcp_config.json'
$kimiConfig = Join-Path $HOME '.kimi-code\mcp.json'
foreach ($configFile in @($claudeConfig, $geminiConfig, $antigravityConfig, $kimiConfig)) { Update-JsonMcpConfig $configFile $servers }
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$codexConfig = Join-Path $codexHome 'config.toml'
Add-CodexMcp $codexConfig 'segunda_mente' $vaultPath
Add-CodexMcp $codexConfig 'aincrad' $snapshotPath

Write-Step 'Configurando a chave da NVIDIA neste computador'
$saveKeyScript = Join-Path $backupPath 'scripts-claude\save-nvidia-key.ps1'
if (Test-Path -LiteralPath $saveKeyScript) {
    $answer = Read-Host 'Você já tem a chave de API da NVIDIA e quer salvá-la agora? (s/N)'
    if ($answer -match '^(s|sim)$') { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $saveKeyScript }
} else { Write-Warning 'Helper de chave NVIDIA não encontrado; os outros recursos continuam instalados.' }

Write-Step 'Concluído'
Write-Host "Cofre principal: $vaultPath"
Write-Host "Snapshot Aincrad: $snapshotPath"
Write-Host "Automações: $backupPath"
if (-not $SkipProjectClone) { Write-Host "Projeto/Graphify: $projectPath\graphify-out" }
Write-Host 'Faça login nas contas do Claude, Google/Gemini/Antigravity e Kimi neste PC. Sessões e tokens antigos não foram copiados.'
Write-Host 'Feche e reabra os terminais e agentes para carregar PATH, MCPs e hooks.'
if ($script:failures.Count -gt 0) {
    Write-Warning "Alguns itens precisam de nova tentativa: $($script:failures -join '; ')"
    exit 2
}
