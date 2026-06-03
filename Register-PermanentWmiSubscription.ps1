#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers a permanent WMI subscription to monitor for IP address changes and execute a PowerShell script when such an event occurs.
.DESCRIPTION
    This script creates a WMI event filter that listens for modifications to network adapter configurations where IP is enabled.
    It also creates a command line event consumer that executes a specified PowerShell script when the event is triggered.
    Finally, it binds the filter and consumer together to establish the subscription.
.NOTES
    - Ensure that the script is run with administrative privileges to register WMI subscriptions.
    - The PowerShell script specified in the CommandLineTemplate will be run as SYSTEM.
    - The subscription created by this script is permanent and will persist until it is manually removed.
    - A preexisting filter, consumer, or binding with the same name will be removed before creating new ones to avoid conflicts.
#>

$ErrorActionPreference = 'Stop'

$Namespace = 'root\subscription'
$EventNamespace = 'root\cimv2'
$ConsumerScriptPath = 'C:\Scripts\Foo.ps1'
$ConsumerExecutionPolicy = 'AllSigned'
$FilterName = 'IPChangeFilter'
$ConsumerName = 'IPChangeConsumer'

$FilterParams = @{
    'Namespace' = $Namespace
    'Class' = '__EventFilter'
    'Arguments' = @{
        'Name' = $FilterName
        'EventNamespace' = $EventNamespace
        'Query' = "SELECT * FROM __InstanceModificationEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_NetworkAdapterConfiguration' AND TargetInstance.IPEnabled = True"
        'QueryLanguage' = 'WQL'
    }
}

$ConsumerParams = @{
    'Namespace' = $Namespace
    'Class' = 'CommandLineEventConsumer'
    'Arguments' = @{
        'Name' = $ConsumerName
        'CommandLineTemplate' = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy $ConsumerExecutionPolicy -File '$ConsumerScriptPath'"
    }
}

$BindingParams = @{
    'Namespace' = $Namespace
    'Class' = '__FilterToConsumerBinding'
}

# the *-Wmi cmdlets appear to be required to interact with bindings
# and are generally more reliable when interacting with WMI this way.
# remove any preexisting binding, filter, or consumers:

function Remove-FilterOrConsumer {
    param (
        [hashtable] $Params
    )
         
    Get-WmiObject `
        -Namespace $Params.Namespace `
        -Class $Params.Class `
        -Filter "Name='$($Params.Arguments.Name)'" |
        Remove-WmiObject

    # verify the object is actually gone before continuing
    [bool] $ObjectExists = Get-WmiObject `
        -Class $Params.Class `
        -Namespace $Params.Namespace |
        Where-Object Name -like "*$($Params.Arguments.Name)*"

    if ($ObjectExists) {
        throw "Failed to remove WMI object: $($Params.Class) $($Params.Arguments.Name) exists after removal."
    }
   
}

try {

    # Bindings must be removed before the filter/consumer they reference.
    # The Filter property on __FilterToConsumerBinding is a full WMI path string, e.g.:
    #   \\.\root\subscription:__EventFilter.Name="IPChangeFilter"
    # Match with -like rather than -eq, and index with [0] to get the string value.

    Get-WmiObject `
        -Namespace $BindingParams.Namespace `
        -Class $BindingParams.Class |
        Where-Object {
            $_.Filter[0] -like "*$($FilterParams.Arguments.Name)*"
        } |
        Remove-WmiObject

    $BindingExists = Get-WmiObject `
        -Namespace $BindingParams.Namespace `
        -Class $BindingParams.Class |
        Where-Object {
            $_.Filter[0] -like "*$($FilterParams.Arguments.Name)*"
        }

    if ($BindingExists) {
        throw "Failed to remove existing WMI binding: Binding exists after deletion."
    }

} catch {

    throw "Failed to remove WMI binding: $_"

}

try {

    Write-Host "Trying to remove existing filter "
    $FilterParams, $ConsumerParams | ForEach-Object { Remove-FilterOrConsumer $_ }

} catch {

    throw "Failed to remove WMI filter or consumer: $_"

}

try {

    Write-Host "Creating WMI filter..."
    $Filter = Set-WmiInstance @FilterParams

    Write-Host "Creating WMI consumer..."
    $Consumer = Set-WmiInstance @ConsumerParams

    Write-Host "Binding filter to consumer..."

    # Use the legacy [wmiclass] accelerator to create the binding instance -
    # Set-WmiInstance does not support __FilterToConsumerBinding reliably.
    $Binding = ([wmiclass]"\\.\$($BindingParams.Namespace):$($BindingParams.Class)").CreateInstance()

    # Assign by RelativePath rather than the raw object reference for reliability.
    $Binding.Filter = $Filter.Path.RelativePath
    $Binding.Consumer = $Consumer.Path.RelativePath

    $Binding.Put()

} catch {

    throw "Error occurred while creating filter, consumer, or binding: $_"

}