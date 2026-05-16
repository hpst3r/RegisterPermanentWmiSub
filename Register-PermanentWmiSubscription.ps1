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

$Namespace = 'root\subscription'
$EventNamespace = 'root\cimv2'

$FilterParams = @{
    'Namespace' = $Namespace
    'Class' = '__EventFilter'
    'Arguments' = @{
        'Name' = 'IPChangeFilter'
        'EventNamespace' = $EventNamespace
        'Query' = "SELECT * FROM __InstanceModificationEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_NetworkAdapterConfiguration' AND TargetInstance.IPEnabled = True"
        'QueryLanguage' = 'WQL'
    }
}

$ConsumerParams = @{
    'Namespace' = $Namespace
    'Class' = 'CommandLineEventConsumer'
    'Arguments' = @{
        'Name' = "IPChangeConsumer"
        'CommandLineTemplate' = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File C:\Scripts\Foo.ps1"
    }
}

$BindingParams = @{
    'Namespace' = $Namespace
    'Class' = '__FilterToConsumerBinding'
}

# the *-Wmi cmdlets appear to be required to interact with bindings
# and are generally more reliable when interacting with WMI this way.
# remove any preexisting binding, filter, or consumers:
Get-WmiObject `
    -Namespace $BindingParams.Namespace `
    -Class $BindingParams.Class |
    Where-Object {
        $_.Filter.Name -eq $FilterParams.Arguments.Name
    } |
    Remove-WmiObject

function Remove-FilterOrConsumer {
    param ( [hashtable] $Params )
         
    Get-WmiObject `
        -Namespace $Params.Namespace `
        -Class $Params.Class `
        -Filter "Name='$($Params.Arguments.Name)'" |
        Remove-WmiObject
   
}

$FilterParams, $ConsumerParams | ForEach-Object { Remove-FilterOrConsumer $_ }

$Filter = Set-WmiInstance @FilterParams
$Consumer = Set-WmiInstance @ConsumerParams

$Binding = ([wmiclass]"\\.\$($BindingParams.Namespace):$($BindingParams.Class)").CreateInstance()

$Binding.Filter = $Filter; $Binding.Consumer = $Consumer

$Binding.Put()
