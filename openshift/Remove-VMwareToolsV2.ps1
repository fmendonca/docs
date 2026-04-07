#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepNetworkAdapters
)

$ProgressFile = 'C:\Windows\Temp\Remove-VMwareTools.progress'
$CurrentStep = 1

# --- FUNCOES ---

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Show-Banner {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "           PETROBRAS - Projeto de Virtualizacao             " -ForegroundColor Cyan
    Write-Host "               Script desenvolvido pela Red Hat             " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Save-Progress {
    param(
        [int]$Step,
        [string]$Description
    )
    try {
        @(
            "Step=$Step"
            "Description=$Description"
            "UpdatedAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ) | Set-Content -Path $script:ProgressFile -Encoding ASCII -Force
        Write-Log "Progresso salvo: etapa $Step - $Description"
    }
    catch {
        Write-Log "Falha ao salvar arquivo de progresso: $($_.Exception.Message)" -Level Warning
    }
}

function Get-SavedProgress {
    if (-not (Test-Path $script:ProgressFile)) {
        return $null
    }

    try {
        $data = @{}
        foreach ($line in Get-Content -Path $script:ProgressFile -ErrorAction Stop) {
            if ($line -match '^(.*?)=(.*)$') {
                $data[$matches[1]] = $matches[2]
            }
        }

        if ($data.ContainsKey('Step')) {
            return [PSCustomObject]@{
                Step        = [int]$data['Step']
                Description = $data['Description']
                UpdatedAt   = $data['UpdatedAt']
            }
        }
    }
    catch {
        Write-Log "Falha ao ler arquivo de progresso: $($_.Exception.Message)" -Level Warning
    }

    return $null
}

function Clear-Progress {
    if (Test-Path $script:ProgressFile) {
        try {
            Remove-Item -Path $script:ProgressFile -Force -ErrorAction Stop
            Write-Log "Arquivo de progresso removido com sucesso." -Level Success
        }
        catch {
            Write-Log "Falha ao remover arquivo de progresso: $($_.Exception.Message)" -Level Warning
        }
    }
}

function Resolve-StartStep {
    $saved = Get-SavedProgress
    if (-not $saved) {
        return 1
    }

    Write-Log "Foi encontrado um arquivo de progresso de execucao anterior." -Level Warning
    Write-Log "Ultima etapa registrada: $($saved.Step) - $($saved.Description)" -Level Warning
    Write-Log "Atualizado em: $($saved.UpdatedAt)" -Level Warning

    if ($Force) {
        Write-Log "Modo Force habilitado. O script sera retomado automaticamente a partir da etapa $($saved.Step)." -Level Warning
        return [int]$saved.Step
    }

    $resume = Read-Host "Deseja retomar a execucao a partir da etapa $($saved.Step)? (s/N)"
    if ($resume -eq 's' -or $resume -eq 'S') {
        Write-Log "Retomando a execucao a partir da etapa $($saved.Step)." -Level Success
        return [int]$saved.Step
    }

    Write-Log "O arquivo de progresso sera removido e a execucao reiniciara a partir da etapa 1." -Level Warning
    Clear-Progress
    return 1
}

function Stop-VMwareProcesses {
    $vmProcesses = @(
        "vmtoolsd.exe",
        "VGAuthService.exe",
        "vmacthlp.exe"
    )
    foreach ($procName in $vmProcesses) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Write-Log "Encerrando processo $($_.ProcessName) (PID: $($_.Id))"
                Stop-Process -Id $_.Id -Force
            } catch {
                Write-Log "Nao foi possivel encerrar o processo $($_.ProcessName): $($_.Exception.Message)" -Level Warning
            }
        }
    }
}

function Take-Ownership {
    param([string]$Path)
    try {
        Write-Log "Assumindo posse de: $Path"
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c takeown /f `"$Path`" && icacls `"$Path`" /grant administrators:F" -Wait -Verb runAs
    } catch {
        Write-Log "Falha ao assumir posse: $($_.Exception.Message)" -Level Warning
    }
}

function Get-VMwareToolsInstallerID {
    Write-Log "Procurando informacoes do instalador do VMware Tools..."
    try {
        foreach ($item in $(Get-ChildItem Registry::HKEY_CLASSES_ROOT\Installer\Products -ErrorAction SilentlyContinue)) {
            $productName = $item.GetValue('ProductName') -as [string]
            if ($productName -eq 'VMware Tools') {
                $productIcon = $item.GetValue('ProductIcon') -as [string]
                if ($productIcon) {
                    $msiMatch = [Regex]::Match($productIcon, '(?<={)(.*?)(?=})')
                    if ($msiMatch.Success) {
                        Write-Log "ID do instalador do VMware Tools encontrado." -Level Success
                        return @{
                            reg_id = $item.PSChildName
                            msi_id = $msiMatch.Value
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Erro ao procurar ID do instalador: $($_.Exception.Message)" -Level Error
    }
    Write-Log "ID do instalador do VMware Tools nao encontrado no registro." -Level Warning
    return $null
}

function Remove-RegistryKey {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Chave de registro removida: $Path" -Level Success
        }
        catch {
            Write-Log "Falha ao remover chave de registro: $Path - $($_.Exception.Message)" -Level Error
        }
    }
}

function Remove-DirectoryWithRetry {
    param(
        [string]$Path,
        [int]$MaxRetries = 3
    )
    if (-not (Test-Path $Path)) {
        return
    }
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer } |
                Sort-Object { $_.FullName.Length } -Descending |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Diretorio removido: $Path" -Level Success
            return
        }
        catch {
            if ($i -eq $MaxRetries) {
                Write-Log "Falha ao remover diretorio apos $MaxRetries tentativas: $Path - $($_.Exception.Message)" -Level Error
            }
            else {
                Write-Log "Tentativa $i/$MaxRetries para o diretorio: $Path" -Level Warning
                Start-Sleep -Seconds 2
            }
        }
    }
}

function Unregister-VMwareDLLs {
    $dllPaths = @(
        "C:\Program Files\VMware\VMware Tools\vmStatsProvider\win64\vmStatsProvider.dll",
        "C:\Program Files\VMware\VMware Tools\vmStatsProvider\win32\vmStatsProvider.dll"
    )
    foreach ($dllPath in $dllPaths) {
        if (Test-Path $dllPath) {
            Take-Ownership -Path $dllPath
            try {
                Write-Log "Desregistrando DLL: $dllPath"
                $process = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s", "/u", "`"$dllPath`"" -Wait -PassThru
                if ($process.ExitCode -eq 0) {
                    Write-Log "DLL desregistrada com sucesso: $dllPath" -Level Success
                }
                else {
                    Write-Log "Falha ao desregistrar DLL: $dllPath (Codigo de saida: $($process.ExitCode))" -Level Warning
                }
            }
            catch {
                Write-Log "Erro ao desregistrar DLL: $dllPath - $($_.Exception.Message)" -Level Error
            }
        }
    }
}

function Remove-VMwareNetworkAdapters {
    if ($KeepNetworkAdapters) {
        Write-Log "Remocao de adaptadores de rede ignorada conforme solicitado."
        return
    }
    Write-Log "Removendo adaptadores de rede VMware..."
    try {
        $vmxnet3Adapters = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*VMXNET3*" }
        foreach ($adapter in $vmxnet3Adapters) {
            Write-Log "Removendo adaptador VMXNET3: $($adapter.Name)"
            Remove-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
        $vmwareDevices = Get-PnpDevice | Where-Object {
            $_.FriendlyName -like "*VMware*" -and
            $_.Class -eq "Net"
        }
        foreach ($device in $vmwareDevices) {
            try {
                Write-Log "Removendo dispositivo: $($device.FriendlyName)"
                $device | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
                $device | Remove-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "Falha ao remover dispositivo: $($device.FriendlyName)" -Level Warning
            }
        }
    }
    catch {
        Write-Log "Erro durante a limpeza dos adaptadores de rede: $($_.Exception.Message)" -Level Error
    }
}

function Set-VirtIOStorageTimeout {
    $regPath        = "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi\Parameters"
    $valueName      = "IoTimeoutValue"
    $timeoutSeconds = 120

    Write-Log "=== Configurando timeout de I/O do driver VirtIO SCSI ===" -Level Info

    if (-not (Test-Path $regPath)) {
        try {
            New-Item -Path $regPath -Force | Out-Null
            Write-Log "Chave de registro criada: $regPath" -Level Success
        }
        catch {
            Write-Log "Falha ao criar chave de registro: $regPath - $($_.Exception.Message)" -Level Error
            return
        }
    }

    try {
        Set-ItemProperty -Path $regPath -Name $valueName -Value $timeoutSeconds -Type DWord -ErrorAction Stop
        Write-Log "IoTimeoutValue definido como $timeoutSeconds segundos em: $regPath" -Level Success
    }
    catch {
        Write-Log "Falha ao definir IoTimeoutValue: $($_.Exception.Message)" -Level Error
        return
    }

    try {
        $result = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop
        Write-Log "Verificacao: $valueName = $($result.$valueName) em [$regPath]" -Level Success
    }
    catch {
        Write-Log "Nao foi possivel verificar o valor IoTimeoutValue: $($_.Exception.Message)" -Level Warning
    }
}

function Disable-WindowsPagingFile {
    Write-Log "=== Desabilitando arquivo de paginacao do Windows ===" -Level Info

    try {
        $pageFileSetting = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pageFileSetting) {
            Write-Log "Arquivo(s) de paginacao encontrado(s):" -Level Info
            $pageFileSetting | ForEach-Object {
                Write-Log "  - $($_.Name)  (Tamanho inicial: $($_.InitialSize) MB, Tamanho maximo: $($_.MaximumSize) MB)" -Level Info
            }
        }
        else {
            Write-Log "Nenhum arquivo de paginacao encontrado (possivelmente ja desabilitado)." -Level Warning
        }

        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        if ($cs.AutomaticManagedPagefile) {
            $cs.AutomaticManagedPagefile = $false
            $cs.Put() | Out-Null
            Write-Log "Gerenciamento automatico de pagefile desabilitado com sucesso." -Level Success
        }
        else {
            Write-Log "Gerenciamento automatico de pagefile ja estava desabilitado." -Level Info
        }

        $allPageFiles = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($allPageFiles) {
            foreach ($pf in $allPageFiles) {
                try {
                    $pf.Delete()
                    Write-Log "Arquivo de paginacao removido: $($pf.Name)" -Level Success
                }
                catch {
                    Write-Log "Falha ao remover pagefile '$($pf.Name)': $($_.Exception.Message)" -Level Warning
                }
            }
        }

        $regPageFilePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
        Set-ItemProperty -Path $regPageFilePath -Name "PagingFiles" -Value "" -Type MultiString -ErrorAction Stop
        Write-Log "Chave 'PagingFiles' zerada no registro: $regPageFilePath" -Level Success

        Write-Log "Arquivo de paginacao desabilitado com sucesso. Alteracao efetiva apos o reboot." -Level Success
    }
    catch {
        Write-Log "Erro ao desabilitar arquivo de paginacao: $($_.Exception.Message)" -Level Error
    }
}

Show-Banner
$CurrentStep = Resolve-StartStep
Write-Log "Execucao iniciando a partir da etapa $CurrentStep." -Level Info

# --- ETAPA 0: Garantir que todos os servicos VMware estao parados e configurados como Manual ---
if ($CurrentStep -le 0) {
    Save-Progress -Step 0 -Description 'Preparacao inicial dos servicos VMware'
    Write-Log "Etapa 0: Verificando status de todos os servicos relacionados ao VMware..."

    $allVMWareServices = Get-Service | Where-Object {
        $_.DisplayName -like "*VMware*" -or
        $_.ServiceName -like "*VMWare*" -or
        $_.ServiceName -like "*VMTools*" -or
        $_.DisplayName -like "*Tools*" -or
        $_.ServiceName -eq "GISvc"
    }

    $servicesActive = $false

    foreach ($svc in $allVMWareServices) {
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)" -Name "Start" -Value 3
            Write-Log "Tipo de inicializacao de '$($svc.DisplayName)' ($($svc.Name)) definido como Manual." -Level Success
        }
        catch {
            Write-Log "Falha ao definir '$($svc.DisplayName)' ($($svc.Name)) como Manual: $($_.Exception.Message)" -Level Warning
        }
        if ($svc.Status -eq 'Running') {
            Write-Log "Servico em execucao: $($svc.DisplayName). Parando..."
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                $servicesActive = $true
            }
            catch {
                Write-Log "Falha ao parar '$($svc.DisplayName)': $($_.Exception.Message)" -Level Warning
            }
        }
    }
}

# --- LOGICA PRINCIPAL ---
Write-Log "=== Script de Remocao Avancada do VMware Tools ===" -Level Success
Write-Log "Executando em: $env:COMPUTERNAME"
Write-Log "Versao do PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "Versao do Sistema Operacional: $([Environment]::OSVersion.VersionString)"

$vmware_tools_ids = Get-VMwareToolsInstallerID

$reg_targets = @(
    "Registry::HKEY_CLASSES_ROOT\Installer\Features\",
    "Registry::HKEY_CLASSES_ROOT\Installer\Products\",
    "HKLM:\SOFTWARE\Classes\Installer\Features\",
    "HKLM:\SOFTWARE\Classes\Installer\Products\",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\"
)

$filesystem_targets = @(
    "C:\Program Files\VMware",
    "C:\Program Files\Common Files\VMware",
    "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\VMware",
    "C:\ProgramData\VMware"
)

$targets = @()
if ($vmware_tools_ids) {
    foreach ($item in $reg_targets) {
        $targets += $item + $vmware_tools_ids.reg_id
    }
    $targets += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{$($vmware_tools_ids.msi_id)}"
}

if ([Environment]::OSVersion.Version.Major -lt 10) {
    $targets += @(
        "HKCR:\CLSID\{D86ADE52-C4D9-4B98-AA0D-9B0C7F1EBBC8}",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{9709436B-5A41-4946-8BE7-2AA433CAF108}",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{FE2F6A2C-196E-4210-9C04-2B1BC21F07EF}"
    )
}

$additional_registry_keys = @(
    "HKLM:\SOFTWARE\VMware, Inc.",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\VMware User Process"
)
foreach ($key in $additional_registry_keys) {
    if (Test-Path $key) { $targets += $key }
}
foreach ($path in $filesystem_targets) {
    if (Test-Path $path) { $targets += $path }
}

Write-Log "Verificando servicos VMware instalados..."
$services = @()
$services += Get-Service -DisplayName "VMware*" -ErrorAction SilentlyContinue
$services += Get-Service -DisplayName "GISvc" -ErrorAction SilentlyContinue

Write-Log "=== RESUMO DA REMOCAO ===" -Level Warning
if ($targets.Count -eq 0 -and $services.Count -eq 0) {
    Write-Log "Nada a fazer! O VMware Tools nao parece estar instalado." -Level Success
    Clear-Progress
    exit 0
}
Write-Log "Os seguintes itens serao removidos:"
Write-Log "Chaves de registro e diretorios:" -Level Warning
$targets | ForEach-Object { Write-Log "  - $_" }
if ($services.Count -gt 0) {
    Write-Log "Servicos:" -Level Warning
    $services | ForEach-Object { Write-Log "  - $($_.DisplayName) ($($_.Name))" }
}
if (-not $KeepNetworkAdapters) {
    Write-Log "Os adaptadores de rede VMware tambem serao removidos." -Level Warning
}

if (-not $Force -and $CurrentStep -le 1) {
    Write-Log "Deseja continuar com a remocao? (s/N)" -Level Warning
    $confirmation = Read-Host
    if ($confirmation -ne 's' -and $confirmation -ne 'S') {
        Write-Log "Operacao cancelada pelo usuario." -Level Info
        exit 0
    }
}

Write-Log "=== INICIANDO PROCESSO DE REMOCAO ===" -Level Success

if ($CurrentStep -le 1) {
    Save-Progress -Step 1 -Description 'Encerramento de processos VMware e desregistro de DLLs'
    Write-Log "Encerrando processos do VMware Tools em execucao..."
    Stop-VMwareProcesses

    Write-Log "Etapa 1: Desregistrando DLLs do VMware..."
    Unregister-VMwareDLLs
}

if ($CurrentStep -le 2) {
    Save-Progress -Step 2 -Description 'Parada e remocao de servicos VMware'
    if ($services.Count -gt 0) {
        Write-Log "Etapa 2: Parando e removendo servicos VMware..."
        foreach ($service in $services) {
            try {
                Write-Log "Parando servico: $($service.DisplayName)"
                Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "Falha ao parar o servico: $($service.Name)" -Level Warning
            }
        }
        if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
            foreach ($service in $services) {
                try {
                    Remove-Service -Name $service.Name -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Log "Servico removido: $($service.DisplayName)" -Level Success
                }
                catch {
                    Write-Log "Falha ao remover servico: $($service.Name)" -Level Warning
                }
            }
        }
        else {
            foreach ($service in $services) {
                try {
                    $result = & sc.exe DELETE $service.Name 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Servico removido: $($service.DisplayName)" -Level Success
                    }
                    else {
                        Write-Log "Falha ao remover servico: $($service.Name) - $result" -Level Warning
                    }
                }
                catch {
                    Write-Log "Erro ao remover servico: $($service.Name)" -Level Warning
                }
            }
        }
    }
}

$dependentServices = @()
if ($CurrentStep -le 3) {
    Save-Progress -Step 3 -Description 'Parada temporaria de servicos dependentes'
    Write-Log "Etapa 3: Parando temporariamente servicos dependentes..."
    try {
        $eventLogDeps    = Get-Service -Name "EventLog" -DependentServices -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        $winmgmtDeps     = Get-Service -Name "winmgmt"  -DependentServices -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        $dependentServices += $eventLogDeps
        $dependentServices += $winmgmtDeps
        Stop-Service -Name "EventLog" -Force -ErrorAction SilentlyContinue
        Stop-Service -Name "wmiApSrv" -Force -ErrorAction SilentlyContinue
        Stop-Service -Name "winmgmt"  -Force -ErrorAction SilentlyContinue
        Write-Log "Aguardando os servicos pararem..."
        Start-Sleep -Seconds 5
    }
    catch {
        Write-Log "Aviso: Nao foi possivel parar alguns servicos dependentes." -Level Warning
    }
}

if ($CurrentStep -le 4) {
    Save-Progress -Step 4 -Description 'Remocao de arquivos e entradas de registro'
    Write-Log "Etapa 4: Removendo arquivos e entradas de registro..."
    foreach ($target in $targets) {
        if ($target.StartsWith('HKLM:') -or $target.StartsWith('HKCR:') -or $target.StartsWith('Registry::')) {
            Remove-RegistryKey -Path $target
        }
        else {
            Remove-DirectoryWithRetry -Path $target
        }
    }
}

if ($CurrentStep -le 5) {
    Save-Progress -Step 5 -Description 'Remocao de adaptadores de rede VMware'
    Write-Log "Etapa 5: Removendo adaptadores de rede VMware..."
    Remove-VMwareNetworkAdapters
}

if ($CurrentStep -le 6) {
    Save-Progress -Step 6 -Description 'Reinicio de servicos dependentes'
    Write-Log "Etapa 6: Reiniciando servicos dependentes..."
    try {
        Start-Service -Name "EventLog" -ErrorAction SilentlyContinue
        Start-Service -Name "wmiApSrv" -ErrorAction SilentlyContinue
        Start-Service -Name "winmgmt"  -ErrorAction SilentlyContinue
        foreach ($serviceName in $dependentServices) {
            try { Start-Service -Name $serviceName -ErrorAction SilentlyContinue }
            catch { }
        }
    }
    catch {
        Write-Log "Aviso: Alguns servicos podem precisar ser reiniciados manualmente." -Level Warning
    }
}

Write-Log "=== VERIFICACAO POS-REMOCAO ===" -Level Success
$remainingServices = Get-Service -DisplayName "VMware*" -ErrorAction SilentlyContinue
if ($remainingServices.Count -gt 0) {
    Write-Log "Aviso: Alguns servicos VMware ainda existem:" -Level Warning
    $remainingServices | ForEach-Object { Write-Log "  - $($_.DisplayName)" -Level Warning }
}
$remainingFiles = @()
foreach ($path in $filesystem_targets) {
    if (Test-Path $path) { $remainingFiles += $path }
}
if ($remainingFiles.Count -gt 0) {
    Write-Log "Aviso: Alguns arquivos/diretorios ainda existem:" -Level Warning
    $remainingFiles | ForEach-Object { Write-Log "  - $_" -Level Warning }
}
if ($remainingServices.Count -eq 0 -and $remainingFiles.Count -eq 0) {
    Write-Log "Remocao do VMware Tools concluida com sucesso!" -Level Success
}
else {
    Write-Log "Remocao do VMware Tools concluida com avisos. Verifique os detalhes acima." -Level Warning
}

if ($CurrentStep -le 7) {
    Save-Progress -Step 7 -Description 'Configuracoes pre-reboot'
    Write-Log "=== Etapa 7: Configuracoes pre-reboot ===" -Level Success
    Set-VirtIOStorageTimeout
    Disable-WindowsPagingFile
}

Write-Log "=== ATENCAO ===" -Level Warning
Write-Log "E necessario reiniciar o sistema para concluir o processo de remocao."
Write-Log "Por favor, reinicie o sistema quando conveniente."

Clear-Progress

if (-not $Force) {
    $rebootNow = Read-Host "Deseja reiniciar agora? (s/N)"
    if ($rebootNow -eq 's' -or $rebootNow -eq 'S') {
        Write-Log "Iniciando reinicializacao do sistema..."
        Restart-Computer -Force
    }
    else {
        Write-Log "Reinicializacao adiada. Lembre-se de reiniciar o sistema em breve." -Level Warning
    }
}
