<#
Author: Erik Verbruggen
Scriptname: VCF Host Preparation
Version: 1.0
Date: 27 oct 2021
Why: because manual configuration is stupid
#>

$vmhosts = import-csv .\vmhosts.csv
$user = "root"
$password = "password"
$license = "license"
$domainname = "domainname"
$dns1 = "dns server"
$dns2 = "dns server"
$searchdomain = "domainname"
$vlan = "vlanid"
$vmnic = "vmnic"
$ntpserver1 = "ntp server"
$ntpserver2 = "ntp server"
$localdatastore = "datastore name"

write-host "Configue PowerCLI to accept invalid ESXi host certificate"
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

foreach ($vmhost in $vmhosts){

    #connect ESXi host
    write-host "Connecting to ESXi host:" $vmhost.ip
    
    connect-viserver -server $vmhost.ip -user $user -password $password | Out-Null
     
    #change (expired) evaluation license to vSphere license      
    write-host "Configuring vSpere license"
    
    $lm = get-view -id 'licensemanager-ha-license-manager'
    $lm.updatelicense($license, $null)  | Out-Null

    #change host network configuration
    write-host "Configuring ESXi host network configuration"
    
    Get-VMHostNetwork | Set-VMHostNetwork -DomainName $domainname -DNSAddress $dns1 , $dns2 -SearchDomain $searchdomain -HostName $vmhost.hostname -Confirm:$false | Out-Null

    #change virtualswitch configuration
    write-host "Configuring virtual switch"
    
    $portgroup = Get-VirtualPortGroup -VirtualSwitch vSwitch0 -Name "VM Network"
    Set-VirtualPortGroup -Name "VM Network" -VLanId $vlan -VirtualPortGroup $portgroup | Out-Null
    get-virtualswitch -name "vSwitch0" | Set-VirtualSwitch -Nic $vmnic -confirm:$false | Out-Null

    #configure SSH service
    write-host "Configuring SSH service"
    
    Get-VMHostService | where-object {$_.key -eq "TSM-SSH"} | set-vmhostservice -Policy on  | Out-Null
    Get-VMHostService | where-object {$_.key -eq "TSM-SSH"} | start-vmhostservice -confirm:$false  | Out-Null

    #configure NTP service
    write-host "Checking configured NTP servers"
    
    $ntplist = Get-VMHostNtpServer

    if(!$ntplist){
        write-host "Adding NTP servers"        
        
        add-vmhostntpserver -ntpserver $ntpserver1  | Out-Null
        add-vmhostntpserver -ntpserver $ntpserver2  | Out-Null
    }
    else{
        write-warning "Updating NTP servers"

        Remove-VMHostNtpServer -ntpserver $ntpList -Confirm:$false
        add-vmhostntpserver -ntpserver $ntpserver1  | Out-Null
        add-vmhostntpserver -ntpserver $ntpserver2  | Out-Null
    }
    
    write-host "Configuring NTP service"
    Get-VMHostService | where-object {$_.key -eq "ntpd"} | set-vmhostservice -Policy on  | Out-Null
    Get-VMHostService | where-object {$_.key -eq "ntpd"} | restart-vmhostservice -confirm:$false  | Out-Null

    #configure scratch location in preparation of datastore removal
    write-host "Configuring scratch location"
    
    Get-AdvancedSetting -Entity $vmhost.ip -name "ScratchConfig.ConfiguredScratchLocation" | Set-AdvancedSetting -Value "/tmp" -Confirm:$false | Out-Null
       
    #remove local datastore
    write-host "Checking for datastores"
    
    $datastores = Get-Datastore

    if(!$datastores){
        write-warning "No datastores exist"
    }
    else{
        foreach($datastore in $datastores){
            write-host "Checking for local datastore:" $localdatastore

            if($datastore.name -eq $localdatastore){
                write-warning "Removing local datastore"    
    
                remove-datastore -datastore $datastore.name -Confirm:$false | Out-Null

            }
            else{

                write-host "Local datastore does not exist"
    
            }
        }
    }

    #check for maintenance mode and exit maintenance mode
    write-host "Checking maintenance mode"
    
    if($vmhost.ConnectionState -eq "Maintenance"){
        write-warning "Exiting maintenance mode"    
    
        set-vmhost -state connected -Confirm:$false | Out-Null   

    }
    else {
        
        write-Host "Host is not in maintenance mode"
    
    }

    #regenerate the self signed certificate
    write-host "Regenerating ESXi certificate"

    $passwordsec = ConvertTo-SecureString -String $password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($user,$passwordsec)

    $certificatecmd1 = "/sbin/generate-certificates"
    $certificatecmd2 = "/etc/init.d/hostd restart && /etc/init.d/vpxa restart"

    $ssh = new-sshsession -computername $vmhost.ip -credential $cred -acceptkey -keepaliveinterval 5
    invoke-sshcommand -sessionid $ssh.sessionid -command $certificatecmd1 -timeout 30 | Out-Null
    invoke-sshcommand -sessionid $ssh.sessionid -command $certificatecmd2 -timeout 30 | Out-Null
    remove-sshsession -sessionid $ssh.sessionid

    #disconnect ESXi host
    Write-Warning "Disconnecting ESXi host"
    disconnect-viserver -Server * -confirm:$false
}