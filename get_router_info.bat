@echo off
:: Кодування UTF-8 для коректного відображення кирилиці
chcp 65001 > nul

set "OutputFile=%~dp0router_info_report.txt"

:: Запускаємо PowerShell і передаємо йому весь блок тексту нижче
more +9 "%~f0" | powershell -NoProfile -ExecutionPolicy Bypass -Command -
exit

# =====================================================================
# Далі йде чистий код PowerShell
# =====================================================================

$logPath = $env:OutputFile
$report = New-Object System.Collections.Generic.List[string]
$report.Add('=== ПОВНИЙ ЗВІТ ПРО ЛОКАЛЬНИЙ РОУТЕР ===')
$report.Add('Дата та час: ' + (Get-Date -Format 'dd-MM-yyyy HH:mm:ss'))
$report.Add('Комп`ютер:   ' + $env:COMPUTERNAME)
$report.Add('-----------------------------------')

# Список ключових слів для пошуку вендора в HTML
$vendors = @('TP-Link', 'ASUS', 'Keenetic', 'Tenda', 'MikroTik', 'Netgear', 'D-Link', 'Huawei', 'ZTE', 'Mercusys', 'Xiaomi', 'Totolink')
$detectedBrand = ""

# 1. Визначення локального IP та MAC-адреси шлюзу
$gatewayIp = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).NextHop

if ($gatewayIp) {
    $report.Add('Внутрішній IP роутера:  ' + $gatewayIp)
    
    # Пінгуємо для оновлення ARP-таблиці
    Test-Connection -ComputerName $gatewayIp -Count 1 -Quiet | Out-Null
    $macAddress = (Get-NetNeighbor -IPAddress $gatewayIp).LinkLayerAddress
    
    if ($macAddress) {
        $report.Add('MAC-адреса роутера:     ' + $macAddress)
        
        # Опитування бази даних виробників за MAC (OUI)
        try {
            $cleanMac = $macAddress -replace '[:-]', ''
            $macOUI = $cleanMac.Substring(0,6)
            $macUri = 'https://api.macvendors.com/' + $macOUI
            $vendorByMac = Invoke-RestMethod -Uri $macUri -Method Get -TimeoutSec 4
            $report.Add('Виробник (база MAC):    ' + $vendorByMac)
        } catch {
            $report.Add('Виробник (база MAC):    Не вдалося отримати (таймаут або ліміт API)')
        }
    } else {
        $report.Add('MAC-адреса роутера:     Не знайдено в ARP-таблиці')
    }

    # Глибокий аналіз веб-сторінки роутера (HTTP/HTTPS)
    $webContent = ""
    $webLinks = ""
    try {
        $webRequest = Invoke-WebRequest -Uri "http://$gatewayIp" -TimeoutSec 4 -UseBasicParsing
        $webContent = $webRequest.Content
        $webLinks = $webRequest.Links | Out-String
    } catch {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
            $webRequest = Invoke-WebRequest -Uri "https://$gatewayIp" -TimeoutSec 4 -UseBasicParsing
            $webContent = $webRequest.Content
            $webLinks = $webRequest.Links | Out-String
        } catch {}
    }

    # Аналізуємо отриманий HTML
    if ($webContent) {
        # Спроба 1: Шукаємо класичний Title
        if ($webContent -match '<title>(.*?)</title>') {
            $detectedBrand = $Matches[1].Trim()
        }
        
        # Спроба 2: Якщо Title порожній, шукаємо згадки брендів у тексті або посиланнях
        if ([string]::IsNullOrEmpty($detectedBrand)) {
            foreach ($v in $vendors) {
                if ($webContent -like "*$v*" -or $webLinks -like "*$v*") {
                    $detectedBrand = "$v (визначено за сигнатурою сторінки)"
                    break
                }
            }
        }
        
        # Спроба 3: Специфічний хак для нових панелей TP-Link (як у вашому випадку)
        if ([string]::IsNullOrEmpty($detectedBrand) -and ($webContent -like "*pc-login-*" -or $webContent -like "*pc-top-product*")) {
            $detectedBrand = "TP-Link (Сучасна веб-панель)"
        }
    }

} else {
    $report.Add('[-] Помилка: Не знайдено основний шлюз мережі')
}
$report.Add('-----------------------------------')

# 2. Визначення публічного (білого) IP
try {
    $publicIp = Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5
    $report.Add('Публічний (білий) IP:   ' + $publicIp)
} catch {
    $report.Add('Публічний (білий) IP:   Не вдалося визначити (немає інтернет-з`єднання)')
}
$report.Add('-----------------------------------')

# 3. Вивід результатів веб-аналізу
$report.Add('[Додаткові дані пристрою]')
if ($detectedBrand) {
    $report.Add('Визначено через Web:    ' + $detectedBrand)
} else {
    $report.Add('Визначено через Web:    Не вдалося розпізнати бренд або веб-інтерфейс закритий')
}

$report.Add('-----------------------------------')
$report.Add('=== КІНЕЦЬ ЗВІТУ ===')

# Запис усього масиву даних у текстовий файл
[System.IO.File]::WriteAllLines($logPath, $report, [System.Text.Encoding]::UTF8)
