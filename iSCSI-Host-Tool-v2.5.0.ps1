#requires -Version 5.1
<#
.SYNOPSIS
    iSCSI Host Tool v2.5.0

.DESCRIPTION
    Windows iSCSI / Pure FlashArray host preparation and registration tool.

    Scope:
      - Windows Server host preparation for Pure FlashArray iSCSI
      - Microsoft iSCSI Initiator initialization
      - MPIO installation and Pure-recommended host baseline
      - IQN discovery
      - Reboot selection and reboot monitoring
      - Prerequisite detection and approved installation
      - PureStoragePowerShellSDK2 connectivity
      - Pure host-name and IQN conflict validation across one or more FlashArrays
      - Safe host creation/reuse across selected arrays
      - Optional Pure host-group creation/use
      - Host-group membership validation and assignment
      - Explicit Windows iSCSI target portal creation
      - Persistent / multipath iSCSI session creation using selected source and target IPs
      - iSCSI Dry Run / change preview and post-change verification
      - Dry-run/change preview
      - Post-change verification

    Explicitly out of scope:
      - Pods
      - Protection Groups
      - Volumes
      - LUN assignment
      - Volume-to-host or volume-to-host-group connections
      - Disk initialization, partitioning, or formatting
      - MPIO policy changes during the iSCSI connection phase
      - ActiveCluster preferred-array changes
      - Failover Cluster creation or Cluster Shared Volume configuration

.NOTES
    No credentials or API tokens are written to disk.
    Pure credentials are retained only in memory for the current tool session.

    Pure SDK:
      PureStoragePowerShellSDK2
      https://www.powershellgallery.com/packages/PureStoragePowerShellSDK2

#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
$script:ToolVersion = "2.5.0"
$script:WindowsCredential = $null
$script:PureCredentials = @{}
$script:PureArrays = @{}
$script:PureArrayInfo = @{}
$script:PureConnected = $false
$script:PrereqsHealthy = $false
$script:PureValidationReady = $false
$script:WindowsAuditComplete = $false
$script:WindowsAuditHostSignature = ""
$script:PurePlan = @()
$script:PureGroupPlan = $null
$script:LastWindowsAuditTime = $null
$script:LastPureValidationTime = $null
$script:LastApplyVerificationTime = $null
$script:LastPreflightTime = $null
$script:PureValidationReason = "Not validated"

# iSCSI Connections phase state
$script:IscsiValidationReady = $false
$script:IscsiValidationReason = "Not validated"
$script:IscsiConnectionPlan = @()
$script:LastIscsiPreflightTime = $null
$script:LastIscsiValidationTime = $null
$script:LastIscsiApplyVerificationTime = $null
$script:IscsiInputSignature = ""
$script:WindowsMpioMaxPathsPerDevice = 32
$script:PureArrayEntries = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:SavedArrayRoot = Join-Path $env:LOCALAPPDATA "iSCSI-Host-Tool"
$script:SavedArrayPath = Join-Path $script:SavedArrayRoot "arrays.dat"
$script:LegacySavedArrayPath = Join-Path $script:SavedArrayRoot "arrays.json"
$script:LegacySavedArrayPath = Join-Path $script:SavedArrayRoot "arrays.json"

$LogRoot = Join-Path $env:LOCALAPPDATA "iSCSI-Host-Tool\Logs"
try {
    if (-not (Test-Path $LogRoot)) {
        New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
    }
}
catch {
    $LogRoot = $env:TEMP
}
$script:LogPath = Join-Path $LogRoot ("iSCSI-Host-Tool-v2-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Open-iSCSIHostToolUserGuide {
    $GuidePath =
        Join-Path `
            (Join-Path $PSScriptRoot "Docs") `
            "USER-GUIDE.html"

    if (-not (Test-Path $GuidePath)) {
        [System.Windows.MessageBox]::Show(
            "The user guide was not found:`n`n$GuidePath",
            "iSCSI Host Tool Help",
            "OK",
            "Warning"
        ) | Out-Null

        return
    }

    try {
        $HelpXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iSCSI Host Tool v$($script:ToolVersion) - User Guide"
        Width="1200"
        Height="800"
        MinWidth="900"
        MinHeight="600"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0"
                   Margin="0,0,0,8">
            <TextBlock Text="iSCSI Host Tool User Guide"
                       FontSize="18"
                       FontWeight="SemiBold"
                       VerticalAlignment="Center"/>
            <TextBlock Text="Version $($script:ToolVersion)"
                       Margin="16,0,0,0"
                       Foreground="Gray"
                       VerticalAlignment="Center"/>
        </DockPanel>

        <WebBrowser x:Name="HelpBrowser"
                    Grid.Row="1"/>

        <StackPanel Grid.Row="2"
                    Orientation="Horizontal"
                    HorizontalAlignment="Right"
                    Margin="0,8,0,0">
            <Button x:Name="RefreshHelpButton"
                    Content="Refresh"
                    Width="90"
                    Height="30"
                    Margin="0,0,8,0"/>
            <Button x:Name="CloseHelpButton"
                    Content="Close"
                    Width="90"
                    Height="30"
                    IsDefault="True"
                    IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

        $Reader =
            New-Object System.Xml.XmlNodeReader ([xml]$HelpXaml)

        $HelpWindow =
            [Windows.Markup.XamlReader]::Load($Reader)

        if ($Window) {
            $HelpWindow.Owner = $Window
        }

        $HelpBrowser =
            $HelpWindow.FindName("HelpBrowser")

        $RefreshHelpButton =
            $HelpWindow.FindName("RefreshHelpButton")

        $CloseHelpButton =
            $HelpWindow.FindName("CloseHelpButton")

        $GuideUri =
            New-Object System.Uri($GuidePath)

        $HelpBrowser.Navigate($GuideUri)

        $RefreshHelpButton.Add_Click({
            $HelpBrowser.Refresh()
        })

        $CloseHelpButton.Add_Click({
            $HelpWindow.Close()
        })

        $null =
            $HelpWindow.ShowDialog()
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Unable to open the integrated user guide.`n`n$($_.Exception.Message)",
            "iSCSI Host Tool Help",
            "OK",
            "Error"
        ) | Out-Null
    }
}
function Write-ToolLog {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","CHANGE")]
        [string]$Level = "INFO"
    )

    $Line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    try {
        Add-Content -Path $script:LogPath -Value $Line -Encoding UTF8
    }
    catch {}
}

Write-ToolLog "iSCSI Host Tool v$($script:ToolVersion) started by $env:USERDOMAIN\$env:USERNAME."

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iSCSI Host Tool v2.5.0"
        Height="850"
        Width="1450"
        MinHeight="720"
        MinWidth="1180"
        WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TabControl x:Name="MainTabs" Grid.Row="0">

            <!-- WINDOWS HOSTS -->
            <TabItem Header="Windows Hosts">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="130"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0"
                               Text="Enter one or more Windows Server hostnames. Use one hostname per line, or separate names with commas."
                               Margin="0,0,0,8"/>

                    <TextBox x:Name="HostTextBox"
                             Grid.Row="1"
                             AcceptsReturn="True"
                             VerticalScrollBarVisibility="Auto"
                             HorizontalScrollBarVisibility="Auto"
                             FontFamily="Consolas"
                             FontSize="13"/>

                    <StackPanel Grid.Row="2"
                                Orientation="Horizontal"
                                Margin="0,10,0,8">
                        <Button x:Name="AuditButton"
                                Content="Audit Hosts"
                                Width="115"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="ConfigureButton"
                                Content="Configure Pure Best Practices"
                                Width="205"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="RebootButton"
                                Content="Reboot Hosts"
                                Width="110"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="WindowsCredentialButton"
                                Content="Set Windows Credential"
                                Width="155"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="WindowsCurrentUserButton"
                                Content="Use Current User"
                                Width="125"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="ClearWindowsButton"
                                Content="Clear Results"
                                Width="110"
                                Height="30"/>
                    </StackPanel>

                    <Border Grid.Row="3"
                            BorderBrush="Gray"
                            BorderThickness="1"
                            Padding="8"
                            Margin="0,0,0,8">
                        <TextBlock TextWrapping="Wrap">
                            Host baseline: MSiSCSI Automatic/Running; Multipath-IO installed; PURE FlashArray registered with Microsoft DSM; Round Robin default; Pure MPIO timers; High Performance power plan. Target portals and iSCSI sessions are configured only from the dedicated iSCSI Connections tab. The tool does not create Pods, volumes, or LUN mappings.
                        </TextBlock>
                    </Border>

                    <DataGrid x:Name="WindowsResultsGrid"
                              Grid.Row="4"
                              AutoGenerateColumns="False"
                              IsReadOnly="True"
                              CanUserAddRows="False"
                              SelectionMode="Extended"
                              SelectionUnit="FullRow"
                              FrozenColumnCount="1"
                              HorizontalScrollBarVisibility="Auto"
                              VerticalScrollBarVisibility="Auto"
                              Margin="0,0,0,10">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Host" Binding="{Binding Host}" Width="120"/>
                            <DataGridTextColumn Header="IQN" Binding="{Binding IQN}" Width="310"/>
                            <DataGridTextColumn Header="MSiSCSI" Binding="{Binding MSiSCSI}" Width="135"/>
                            <DataGridTextColumn Header="MPIO" Binding="{Binding MPIO}" Width="105"/>
                            <DataGridTextColumn Header="PURE DSM" Binding="{Binding PureDSM}" Width="115"/>
                            <DataGridTextColumn Header="LB Policy" Binding="{Binding LBPolicy}" Width="95"/>
                            <DataGridTextColumn Header="MPIO Timers" Binding="{Binding MPIOTimers}" Width="135"/>
                            <DataGridTextColumn Header="Power Plan" Binding="{Binding PowerPlan}" Width="140"/>
                            <DataGridTextColumn Header="Reboot Required" Binding="{Binding RebootRequired}" Width="125"/>
                            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <StackPanel Grid.Row="5"
                                Orientation="Horizontal">
                        <Button x:Name="CopyIQNButton"
                                Content="Copy IQNs"
                                Width="110"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="ExportWindowsButton"
                                Content="Export CSV"
                                Width="110"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="WindowsDetailsButton"
                                Content="Show Selected Status"
                                Width="155"
                                Height="30"/>
                    </StackPanel>
                </Grid>
            </TabItem>

            <!-- PURE REGISTRATION -->
            <TabItem Header="Pure Registration">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <GroupBox Grid.Row="0" Header="Arrays" Margin="0,0,0,8" MinHeight="255">
                        <Grid Margin="8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="115"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                                                    <TextBlock Grid.Row="0"
                                   Grid.Column="0"
                                   Grid.ColumnSpan="2"
                                   Margin="0,0,0,8"
                                   TextWrapping="Wrap">
                            <Run Text="Add and test each array before validation. Successfully connected arrays are saved for future sessions."/>
                            <LineBreak/>
                            <Run Text="Credentials are never saved. Saved array identities are encrypted for this Windows user and computer."/>
                        </TextBlock>

                            <DataGrid x:Name="FlashArrayGrid"
                                      Grid.Row="1" Grid.Column="0"
                                      AutoGenerateColumns="False"
                                      IsReadOnly="True"
                                      CanUserAddRows="False"
                                      SelectionMode="Single"
                                      VerticalScrollBarVisibility="Auto"
                                      Margin="0,0,12,0">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Array" Binding="{Binding Endpoint}" Width="280"/>
                                    <DataGridTextColumn Header="Username" Binding="{Binding Username}" Width="170"/>
                                    <DataGridTextColumn Header="Array Name" Binding="{Binding ArrayName}" Width="170"/>
                                    <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>

                            <StackPanel Grid.Row="1"
                                        Grid.Column="1"
                                        VerticalAlignment="Top" Margin="0,0,0,6" Grid.RowSpan="2">
                                <Button x:Name="AddPureArrayButton"
                                        Content="Add"
                                        Width="115"
                                        Height="30"
                                        ToolTip="Add Array"/>

                                <Button x:Name="ConnectSavedArraysButton" IsEnabled="False"
                                        Content="Connect Saved"
                                        Width="115"
                                        Height="30"
                                        Margin="0,6,0,0"
                                        ToolTip="Reauthenticate and connect saved arrays"/>
                                                            <Button x:Name="RemoveArrayButton"
                                        Content="Remove"
                                        Width="115"
                                        Height="30"
                                        Margin="0,6,0,0"
                                        IsEnabled="False"
                                        ToolTip="Remove the selected array from this tool only"/>
                                <Button x:Name="RetestArrayButton"
                                        Content="Reconnect"
                                        Width="115"
                                        Height="30"
                                        Margin="0,6,0,0"
                                        IsEnabled="False"
                                        ToolTip="Retest and reconnect the selected array"/></StackPanel>

                            <CheckBox x:Name="IgnoreCertificateCheckBox"
                                      Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2"
                                      Content="Ignore array certificate validation errors"
                                      IsChecked="False"
                                      Margin="0,8,0,0"/>
                        </Grid>
                    </GroupBox>

                    <GroupBox Grid.Row="1" Header="Host Group" Margin="0,0,0,8">
                        <Grid Margin="8">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="300"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <RadioButton x:Name="NoHostGroupRadio"
                                         Grid.Column="0"
                                         Content="No Host Group"
                                         IsChecked="True"
                                         GroupName="HostGroupMode"
                                         Margin="0,0,20,0"/>

                            <RadioButton x:Name="CreateHostGroupRadio"
                                         Grid.Column="1"
                                         Content="Create Host Group"
                                         GroupName="HostGroupMode"
                                         Margin="0,0,20,0"/>

                            <RadioButton x:Name="ExistingHostGroupRadio"
                                         Grid.Column="2"
                                         Content="Use Existing Host Group"
                                         GroupName="HostGroupMode"
                                         Margin="0,0,20,0"/>

                            <ComboBox x:Name="HostGroupTextBox"
                                     Grid.Column="3"
                                     Height="26"
                                     IsEnabled="False"
                                     ToolTip="Host group name" IsEditable="True" IsTextSearchEnabled="True" StaysOpenOnEdit="True"/>
                        </Grid>
                    </GroupBox>

                    <StackPanel Grid.Row="2"
                                Orientation="Horizontal"
                                Margin="0,0,0,8">
                                                <Button x:Name="PreflightButton"
                                Content="Connectivity Preflight"
                                Width="150"
                                Height="30"
                                Margin="0,0,8,0"/><Button x:Name="ValidatePureButton" IsEnabled="False"
                                Content="Validate / Dry Run"
                                Width="145"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="ReviewConflictButton"
                                Content="Review / Resolve Conflict"
                                Width="185"
                                Height="30"
                                IsEnabled="False"
                                Margin="0,0,8,0"/>
                        <Button x:Name="ApplyPureButton"
                                Content="Apply Pure Registration"
                                Width="170"
                                Height="30"
                                IsEnabled="False"
                                Margin="0,0,8,0"/>
                        <Button x:Name="ExportPureButton"
                                Content="Export Validation"
                                Width="130"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="PureDetailsButton"
                                Content="Show Change Preview"
                                Width="150"
                                Height="30"/>
                    </StackPanel>

                    <Border Grid.Row="3"
                            BorderBrush="Gray"
                            BorderThickness="1"
                            Padding="8"
                            Margin="0,0,0,8">
                        <TextBlock x:Name="PureSummaryText"
                                   Text="Add or reconnect at least one array, then run Validate / Dry Run. Conflicts block Apply."
                                   TextWrapping="Wrap"/>
                    </Border>

                    <DataGrid x:Name="PureResultsGrid"
                              Grid.Row="4"
                              AutoGenerateColumns="False"
                              IsReadOnly="True"
                              CanUserAddRows="False"
                              SelectionMode="Single"
                              FrozenColumnCount="1"
                              HorizontalScrollBarVisibility="Auto"
                              VerticalScrollBarVisibility="Auto">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Host" Binding="{Binding Host}" Width="130"/>
                            <DataGridTextColumn Header="IQN" Binding="{Binding IQN}" Width="310"/>
                            <DataGridTextColumn Header="Array" Binding="{Binding FlashArray}" Width="240"/>
                            <DataGridTextColumn Header="State" Binding="{Binding State}" Width="140"/>
                            <DataGridTextColumn Header="Host Group" Binding="{Binding HostGroup}" Width="180"/>
                            <DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="190"/>
                            <DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <TextBlock Grid.Row="5"
                               Text="This tab manages only Pure host objects and optional host-group membership. It does not create or connect volumes."
                               Margin="0,8,0,0"
                               FontStyle="Italic"/>
                </Grid>
            </TabItem>

            <!-- ISCSI CONNECTIONS -->
            <TabItem Header="iSCSI Connections">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0"
                               Margin="0,0,0,8"
                               TextWrapping="Wrap"
                               Text="Define explicit Windows iSCSI source/target mappings. The tool does not assume NIC names, target counts, site topology, path counts, or that every host connects to every target."/>

                    <GroupBox Grid.Row="1"
                              Header="Connection Settings"
                              Margin="0,0,0,8">
                        <Grid Margin="8">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0"
                                        Orientation="Horizontal"
                                        Margin="0,0,0,8">
                                <CheckBox x:Name="IscsiPersistentCheckBox"
                                          Content="Persistent connections"
                                          IsChecked="True"
                                          VerticalAlignment="Center"
                                          Margin="0,0,20,0"/>
                                <CheckBox x:Name="IscsiMultipathCheckBox"
                                          Content="Multipath enabled"
                                          IsChecked="True"
                                          VerticalAlignment="Center"
                                          Margin="0,0,20,0"/>
                                <TextBlock Text="Expected minimum paths (optional):"
                                           VerticalAlignment="Center"
                                           Margin="0,0,6,0"/>
                                <TextBox x:Name="IscsiMinimumPathsTextBox"
                                         Width="55"
                                         Height="25"
                                         VerticalContentAlignment="Center"
                                         ToolTip="Leave blank to avoid enforcing an environment-specific minimum."/>
                            </StackPanel>

                            <Grid Grid.Row="1">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="150"/>
                                    <ColumnDefinition Width="225"/>
                                    <ColumnDefinition Width="180"/>
                                    <ColumnDefinition Width="235"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,8,0">
                                    <TextBlock Text="Host" Margin="0,0,0,3"/>
                                    <ComboBox x:Name="IscsiHostComboBox"
                                              Height="26"
                                              DisplayMemberPath="Display"
                                              SelectedValuePath="Host"/>
                                </StackPanel>

                                <StackPanel Grid.Column="1" Margin="0,0,8,0">
                                    <TextBlock Text="Source NIC / IP" Margin="0,0,0,3"/>
                                    <ComboBox x:Name="IscsiSourceComboBox"
                                              Height="26"
                                              DisplayMemberPath="Display"
                                              SelectedValuePath="IPAddress"/>
                                </StackPanel>

                                <StackPanel Grid.Column="2" Margin="0,0,8,0">
                                    <TextBlock Text="Pure Array" Margin="0,0,0,3"/>
                                    <ComboBox x:Name="IscsiArrayComboBox"
                                              Height="26"
                                              DisplayMemberPath="Display"
                                              SelectedValuePath="Identity"/>
                                </StackPanel>

                                <StackPanel Grid.Column="3" Margin="0,0,8,0">
                                    <TextBlock Text="Target Port / IP" Margin="0,0,0,3"/>
                                    <ComboBox x:Name="IscsiTargetComboBox"
                                              Height="26"
                                              DisplayMemberPath="Display"
                                              SelectedValuePath="IPAddress"/>
                                </StackPanel>

                                <StackPanel Grid.Column="4" Margin="0,0,8,0">
                                    <TextBlock Text="Target IQN" Margin="0,0,0,3"/>
                                    <TextBox x:Name="IscsiTargetIqnTextBox"
                                             Height="26"
                                             IsReadOnly="True"
                                             VerticalContentAlignment="Center"/>
                                </StackPanel>

                                <Button x:Name="IscsiAddMappingButton"
                                        Grid.Column="5"
                                        Content="Add Mapping"
                                        Width="105"
                                        Height="28"
                                        VerticalAlignment="Bottom"
                                        Margin="0,0,8,0"/>

                                <StackPanel Grid.Column="6"
                                            Orientation="Horizontal"
                                            VerticalAlignment="Bottom">
                                    <Button x:Name="IscsiBuildPlanButton"
                                            Content="Build Recommended Plan"
                                            Width="175"
                                            Height="28"
                                            Margin="0,0,8,0"
                                            ToolTip="Read-only discovery. Builds an editable same-subnet iSCSI mapping proposal across audited hosts and connected Pure arrays."/>
                                    <Button x:Name="IscsiRefreshChoicesButton"
                                            Content="Refresh"
                                            Width="80"
                                            Height="28"/>
                                </StackPanel>
                            </Grid>
                        </Grid>
                    </GroupBox>

                    <DataGrid x:Name="IscsiMappingGrid"
                              Grid.Row="2"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              SelectionMode="Single"
                              FrozenColumnCount="1"
                              HorizontalScrollBarVisibility="Auto"
                              VerticalScrollBarVisibility="Auto"
                              Margin="0,0,0,8">
                        <DataGrid.Columns>
                            <DataGridCheckBoxColumn Header="Use" Binding="{Binding Include}" Width="45" IsReadOnly="False"/>
                            <DataGridTextColumn Header="Host" Binding="{Binding Host}" Width="125"/>
                            <DataGridTextColumn Header="Source IP" Binding="{Binding SourceIP}" Width="135"/>
                            <DataGridTextColumn Header="Array" Binding="{Binding Array}" Width="170"/>
                            <DataGridTextColumn Header="Target IP" Binding="{Binding TargetIP}" Width="135"/>
                            <DataGridTextColumn Header="Target IQN" Binding="{Binding TargetIQN}" Width="285" IsReadOnly="True"/>
                            <DataGridTextColumn Header="TCP/3260" Binding="{Binding TCP3260}" Width="90" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Portal" Binding="{Binding PortalState}" Width="90" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Session" Binding="{Binding SessionState}" Width="90" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="185" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Result" Binding="{Binding Result}" Width="*" IsReadOnly="True"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <StackPanel Grid.Row="3"
                                Orientation="Horizontal"
                                Margin="0,0,0,8">
                        <Button x:Name="IscsiValidateButton"
                                Content="Validate / Dry Run"
                                Width="145"
                                Height="30"
                                IsEnabled="False"
                                Margin="0,0,8,0"/>
                        <Button x:Name="IscsiPreviewButton"
                                Content="Show Change Preview"
                                Width="155"
                                Height="30"
                                IsEnabled="False"
                                Margin="0,0,8,0"/>
                        <Button x:Name="IscsiApplyButton"
                                Content="Apply iSCSI Connections"
                                Width="180"
                                Height="30"
                                IsEnabled="False"
                                Margin="0,0,8,0"/>
                        <Button x:Name="IscsiExportButton"
                                Content="Export CSV"
                                Width="105"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="IscsiRemoveMappingButton"
                                Content="Remove Selected"
                                Width="125"
                                Height="30"/>
                    </StackPanel>

                    <Border Grid.Row="4"
                            BorderBrush="Gray"
                            BorderThickness="1"
                            Padding="8">
                        <TextBlock x:Name="IscsiSummaryText"
                                   TextWrapping="Wrap"
                                   Text="Recommended workflow: Build Recommended Plan, review/edit or uncheck rows, then Validate / Dry Run. The planner uses same-subnet host/Pure target discovery only; manual selectors remain available for exceptions. Existing correct portals and sessions are MATCH and are not recreated."/>
                    </Border>
                </Grid>
            </TabItem>

            <!-- PREREQUISITES -->
            <TabItem Header="Prerequisites">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0"
                               Text="Run prerequisite checks before Pure registration. Missing required components are never installed without approval."
                               TextWrapping="Wrap"
                               Margin="0,0,0,10"/>

                    <StackPanel Grid.Row="1"
                                Orientation="Horizontal"
                                Margin="0,0,0,10">
                        <Button x:Name="CheckPrereqButton"
                                Content="Check Prerequisites"
                                Width="145"
                                Height="30"
                                Margin="0,0,8,0"/>
                        <Button x:Name="InstallPrereqButton"
                                Content="Install Missing"
                                Width="130"
                                Height="30"
                                IsEnabled="False"/>
                    </StackPanel>

                    <DataGrid x:Name="PrereqGrid"
                              Grid.Row="2"
                              AutoGenerateColumns="False"
                              IsReadOnly="True"

                              CanUserAddRows="False">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Component" Binding="{Binding Component}" Width="260"/>
                            <DataGridTextColumn Header="Required" Binding="{Binding Required}" Width="110"/>
                            <DataGridTextColumn Header="Detected" Binding="{Binding Detected}" Width="220"/>
                            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="130"/>
                            <DataGridTextColumn Header="Notes" Binding="{Binding Notes}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <TextBlock x:Name="PrereqSummaryText"
                               Grid.Row="3"
                               Text="Prerequisites have not been checked."
                               Margin="0,10,0,0"
                               TextWrapping="Wrap"/>
                </Grid>
            </TabItem>

        </TabControl>

        <StatusBar Grid.Row="1" Margin="0,8,0,0">
            <StatusBarItem>
                <TextBlock x:Name="GlobalStatusText" Text="Ready"/>
            </StatusBarItem>
                    <Separator/>
            <Button x:Name="HelpButton"
                    Content="Help"
                    Width="70"
                    Height="24"
                    Margin="6,0,0,0"
                    ToolTip="Open operator help"/>            <Separator/>
            <StatusBarItem>
                <TextBlock x:Name="SessionStateText"
                           Text="Audit: NOT RUN | Arrays: 0/0 | Validation: NOT RUN"
                           Margin="8,0,8,0"/>
            </StatusBarItem>            <Separator/>
            <Button x:Name="ViewLogButton"
                    Content="View Log"
                    Width="75"
                    Height="24"
                    Margin="4,0,0,0"/>
            <Button x:Name="AboutButton"
                    Content="About"
                    Width="65"
                    Height="24"
                    Margin="4,0,0,0"/>            <Separator/>
            <Button x:Name="ExportAllButton"
                    Content="Export All"
                    Width="80"
                    Height="24"
                    Margin="4,0,0,0"
                    ToolTip="Export Windows audit, Pure validation, change preview, and current log"/>
            <Button x:Name="ResetSessionButton"
                    Content="Reset Session"
                    Width="95"
                    Height="24"
                    Margin="4,0,0,0"
                    ToolTip="Clear session state and in-memory credentials without deleting saved arrays"/></StatusBar>
    </Grid>
</Window>
'@

$Reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($Reader)

# Window controls
$MainTabs = $Window.FindName("MainTabs")
$GlobalStatusText = $Window.FindName("GlobalStatusText")
$ExportAllButton = $Window.FindName("ExportAllButton")
$ResetSessionButton = $Window.FindName("ResetSessionButton")
$SessionStateText = $Window.FindName("SessionStateText")
$RemoveArrayButton = $Window.FindName("RemoveArrayButton")
$RetestArrayButton = $Window.FindName("RetestArrayButton")
$PreflightButton = $Window.FindName("PreflightButton")
$ViewLogButton = $Window.FindName("ViewLogButton")
$AboutButton = $Window.FindName("AboutButton")
$HelpButton = $Window.FindName("HelpButton")

# Windows tab
$HostTextBox = $Window.FindName("HostTextBox")
$AuditButton = $Window.FindName("AuditButton")
$ConfigureButton = $Window.FindName("ConfigureButton")
$RebootButton = $Window.FindName("RebootButton")
$WindowsCredentialButton = $Window.FindName("WindowsCredentialButton")
$WindowsCurrentUserButton = $Window.FindName("WindowsCurrentUserButton")
$ClearWindowsButton = $Window.FindName("ClearWindowsButton")
$WindowsResultsGrid = $Window.FindName("WindowsResultsGrid")
$CopyIQNButton = $Window.FindName("CopyIQNButton")
$ExportWindowsButton = $Window.FindName("ExportWindowsButton")
$WindowsDetailsButton = $Window.FindName("WindowsDetailsButton")

# Pure tab
$FlashArrayGrid = $Window.FindName("FlashArrayGrid")
$AddPureArrayButton = $Window.FindName("AddPureArrayButton")
$ConnectSavedArraysButton = $Window.FindName("ConnectSavedArraysButton")
$IgnoreCertificateCheckBox = $Window.FindName("IgnoreCertificateCheckBox")
$NoHostGroupRadio = $Window.FindName("NoHostGroupRadio")
$CreateHostGroupRadio = $Window.FindName("CreateHostGroupRadio")
$ExistingHostGroupRadio = $Window.FindName("ExistingHostGroupRadio")
$HostGroupTextBox = $Window.FindName("HostGroupTextBox")
$ValidatePureButton = $Window.FindName("ValidatePureButton")
$ReviewConflictButton = $Window.FindName("ReviewConflictButton")
$ApplyPureButton = $Window.FindName("ApplyPureButton")
$ExportPureButton = $Window.FindName("ExportPureButton")
$PureDetailsButton = $Window.FindName("PureDetailsButton")
$PureSummaryText = $Window.FindName("PureSummaryText")
$PureResultsGrid = $Window.FindName("PureResultsGrid")

# iSCSI Connections tab
$IscsiPersistentCheckBox = $Window.FindName("IscsiPersistentCheckBox")
$IscsiMultipathCheckBox = $Window.FindName("IscsiMultipathCheckBox")
$IscsiMinimumPathsTextBox = $Window.FindName("IscsiMinimumPathsTextBox")
$IscsiHostComboBox = $Window.FindName("IscsiHostComboBox")
$IscsiSourceComboBox = $Window.FindName("IscsiSourceComboBox")
$IscsiArrayComboBox = $Window.FindName("IscsiArrayComboBox")
$IscsiTargetComboBox = $Window.FindName("IscsiTargetComboBox")
$IscsiTargetIqnTextBox = $Window.FindName("IscsiTargetIqnTextBox")
$IscsiAddMappingButton = $Window.FindName("IscsiAddMappingButton")
$IscsiRemoveMappingButton = $Window.FindName("IscsiRemoveMappingButton")
$IscsiBuildPlanButton = $Window.FindName("IscsiBuildPlanButton")
$IscsiRefreshChoicesButton = $Window.FindName("IscsiRefreshChoicesButton")
$IscsiMappingGrid = $Window.FindName("IscsiMappingGrid")
$IscsiValidateButton = $Window.FindName("IscsiValidateButton")
$IscsiPreviewButton = $Window.FindName("IscsiPreviewButton")
$IscsiApplyButton = $Window.FindName("IscsiApplyButton")
$IscsiExportButton = $Window.FindName("IscsiExportButton")
$IscsiSummaryText = $Window.FindName("IscsiSummaryText")

# Prereq tab
$CheckPrereqButton = $Window.FindName("CheckPrereqButton")
$InstallPrereqButton = $Window.FindName("InstallPrereqButton")
$PrereqGrid = $Window.FindName("PrereqGrid")
$PrereqSummaryText = $Window.FindName("PrereqSummaryText")

$script:WindowsResults = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$WindowsResultsGrid.ItemsSource = $script:WindowsResults

$script:PureResults = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$PureResultsGrid.ItemsSource = $script:PureResults
$FlashArrayGrid.ItemsSource = $script:PureArrayEntries

$script:IscsiConnectionResults = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$IscsiMappingGrid.ItemsSource = $script:IscsiConnectionResults

$script:PrereqResults = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$PrereqGrid.ItemsSource = $script:PrereqResults

$HostTextBox.Text = @"
"@.Trim()

function Update-SessionStateBanner {
    if (-not $SessionStateText) {
        return
    }

    $AuditText =
        if ($script:WindowsAuditComplete) {
            if ($script:LastWindowsAuditTime) {
                "PASS " + $script:LastWindowsAuditTime.ToString("HH:mm")
            }
            else {
                "PASS"
            }
        }
        elseif ($script:WindowsResults.Count -gt 0) {
            "STALE/INCOMPLETE"
        }
        else {
            "NOT RUN"
        }

    $TotalArrays = @($script:PureArrayEntries).Count
    $ConnectedArrays =
        @(
            $script:PureArrayEntries |
                Where-Object { $_.Status -eq "Connected" }
        ).Count

    $ValidationText =
        if ($script:PureValidationReady) {
            if ($script:LastPureValidationTime) {
                "PASS " + $script:LastPureValidationTime.ToString("HH:mm")
            }
            else {
                "PASS"
            }
        }
        else {
            $script:PureValidationReason
        }

    $VerifyText =
        if ($script:LastApplyVerificationTime) {
            " | Verify: " + $script:LastApplyVerificationTime.ToString("HH:mm")
        }
        else {
            ""
        }

    $IscsiText =
        if ($script:LastIscsiApplyVerificationTime) {
            "VERIFIED " + $script:LastIscsiApplyVerificationTime.ToString("HH:mm")
        }
        elseif ($script:IscsiValidationReady) {
            if ($script:LastIscsiValidationTime) {
                "READY " + $script:LastIscsiValidationTime.ToString("HH:mm")
            }
            else {
                "READY"
            }
        }
        else {
            $script:IscsiValidationReason
        }

    $SessionStateText.Text =
        "Audit: $AuditText | Arrays: $ConnectedArrays/$TotalArrays Connected | Validation: $ValidationText$VerifyText | iSCSI: $IscsiText"

    Update-ValidationControls
    Update-IscsiControls
}

function Invalidate-PureValidationState {
    param(
        [string]$Reason = "Configuration changed"
    )

    $script:PureValidationReady = $false
    $script:LastPureValidationTime = $null
    $script:PureValidationReason = "STALE"

    if ($ApplyPureButton) {
        $ApplyPureButton.IsEnabled = $false
    }

    if ($ReviewConflictButton) {
        $ReviewConflictButton.IsEnabled = $false
    }

    Write-ToolLog "Pure validation invalidated: $Reason." "INFO"

    Update-SessionStateBanner

    Update-ValidationControls
}

function Test-AllArraysConnected {
    $Entries = @($script:PureArrayEntries)

    if ($Entries.Count -eq 0) {
        return $false
    }

    $Disconnected = @(
        $Entries |
            Where-Object {
                $_.Status -ne "Connected" -or
                -not $script:PureArrays.ContainsKey([string]$_.Endpoint)
            }
    )

    return ($Disconnected.Count -eq 0)
}

function Get-ArrayConnectionSummary {
    $Entries = @($script:PureArrayEntries)
    $Connected = @($Entries | Where-Object Status -eq "Connected").Count

    [pscustomobject]@{
        Total      = $Entries.Count
        Connected  = $Connected
        AllConnected = (
            $Entries.Count -gt 0 -and
            $Connected -eq $Entries.Count
        )
    }
}

function Remove-SelectedArray {
    $Selected = $FlashArrayGrid.SelectedItem

    if (-not $Selected) {
        return
    }

    $Endpoint = [string]$Selected.Endpoint
    $ArrayName = [string]$Selected.ArrayName

    $Message = @"
Remove this array from the iSCSI Host Tool?

Endpoint: $Endpoint
Array Name: $ArrayName

This removes only the local saved/in-memory array definition.

It does NOT:
- delete or modify the Pure array
- delete Pure hosts
- change host groups
- change volumes
- change LUNs
- change mappings
"@

    $Confirm =
        [System.Windows.MessageBox]::Show(
            $Message,
            "Remove Array From Tool",
            "YesNo",
            "Warning"
        )

    if ($Confirm -ne "Yes") {
        return
    }

    if ($script:PureArrays.ContainsKey($Endpoint)) {
        $script:PureArrays.Remove($Endpoint)
    }

    if ($script:PureCredentials.ContainsKey($Endpoint)) {
        $script:PureCredentials.Remove($Endpoint)
    }

    if ($script:PureArrayInfo.ContainsKey($Endpoint)) {
        $script:PureArrayInfo.Remove($Endpoint)
    }

    $script:PureArrayEntries.Remove($Selected)

    $script:PureConnected =
        @(
            $script:PureArrayEntries |
                Where-Object Status -eq "Connected"
        ).Count -gt 0

    if (Get-Command Save-SavedArrays -ErrorAction SilentlyContinue) {
        Save-SavedArrays
    }

    Invalidate-PureValidationState `
        -Reason "Array '$Endpoint' removed"

    $FlashArrayGrid.Items.Refresh()

    Set-GlobalStatus `
        "Removed array $Endpoint from the tool."

    Write-ToolLog `
        "Removed local array definition '$Endpoint'. No Pure storage object was changed." `
        "CHANGE"

    Update-ValidationControls
}

function Retest-SelectedArray {
    $Selected = $FlashArrayGrid.SelectedItem

    if (-not $Selected) {
        return
    }

    if (-not (Test-PurePrerequisitesForConnection)) {
        return
    }

    $Endpoint = [string]$Selected.Endpoint

    $Credential =
        Get-Credential `
            -Message "Reauthenticate to array $Endpoint"

    if (-not $Credential) {
        return
    }

    Set-BusyState $true

    try {
        $Selected.Status = "Connecting..."
        $FlashArrayGrid.Items.Refresh()

        $ConnectParams = @{
            Endpoint    = $Endpoint
            Credential  = $Credential
            ErrorAction = "Stop"
        }

        if ($IgnoreCertificateCheckBox.IsChecked) {
            $ConnectParams.IgnoreCertificateError = $true
        }

        $Array = Connect-Pfa2Array @ConnectParams
        $Info = Get-Pfa2Array -Array $Array -ErrorAction Stop

        $Selected.Username = [string]$Credential.UserName
        $Selected.ArrayName =
            if ($Info -and $Info.Name) {
                [string]$Info.Name
            }
            else {
                [string]$Selected.ArrayName
            }

        $Selected.Status = "Connected"
        $Selected.Credential = $Credential
        $Selected.Connection = $Array

        if ($Selected.PSObject.Properties.Name -contains "SavedState") {
            $Selected.SavedState = "Yes"
        }

        $script:PureCredentials[$Endpoint] = $Credential
        $script:PureArrays[$Endpoint] = $Array
        $script:PureArrayInfo[$Endpoint] = $Info
        $script:PureConnected = $true

        if (Get-Command Save-SavedArrays -ErrorAction SilentlyContinue) {
            Save-SavedArrays
        }

        Invalidate-PureValidationState `
            -Reason "Array '$Endpoint' reconnected"

        Set-GlobalStatus `
            "Array $Endpoint connected successfully."

        Write-ToolLog `
            "Retested and connected array $Endpoint as $($Credential.UserName)."
    }
    catch {
        $Selected.Status = "Connection Failed"

        if ($Selected.PSObject.Properties.Name -contains "Credential") {
            $Selected.Credential = $null
        }

        if ($Selected.PSObject.Properties.Name -contains "Connection") {
            $Selected.Connection = $null
        }

        if ($script:PureArrays.ContainsKey($Endpoint)) {
            $script:PureArrays.Remove($Endpoint)
        }

        if ($script:PureCredentials.ContainsKey($Endpoint)) {
            $script:PureCredentials.Remove($Endpoint)
        }

        $script:PureConnected =
            @(
                $script:PureArrayEntries |
                    Where-Object Status -eq "Connected"
            ).Count -gt 0

        Invalidate-PureValidationState `
            -Reason "Array '$Endpoint' retest failed"

        [System.Windows.MessageBox]::Show(
            "Unable to reconnect to $Endpoint.`n`n$($_.Exception.Message)",
            "Array Connection Failed",
            "OK",
            "Error"
        ) | Out-Null
    }
    finally {
        $FlashArrayGrid.Items.Refresh()
        Set-BusyState $false
        Update-SessionStateBanner
    }

    Update-ValidationControls

    Refresh-ExistingHostGroups | Out-Null
}

function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 2500
    )

    $Client = New-Object System.Net.Sockets.TcpClient

    try {
        $Async = $Client.BeginConnect(
            $ComputerName,
            $Port,
            $null,
            $null
        )

        if (-not $Async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds,$false)) {
            return $false
        }

        $Client.EndConnect($Async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $Client.Close()
    }
}

function Invoke-ConnectivityPreflight {
    $Lines = New-Object System.Collections.Generic.List[string]
    $Failures = 0

    $Lines.Add("CONNECTIVITY PREFLIGHT")
    $Lines.Add("")

    $Hosts = @(Get-HostList $HostTextBox.Text)

    if ($Hosts.Count -gt 0) {
        $Lines.Add("Windows Hosts:")

        foreach ($HostName in $Hosts) {
            $Dns = $false
            $WinRM = $false

            try {
                [System.Net.Dns]::GetHostAddresses($HostName) | Out-Null
                $Dns = $true
            }
            catch {}

            if ($Dns) {
                try {
                    $Params = @{
                        ComputerName = $HostName
                        ErrorAction  = "Stop"
                    }

                    if ($script:WindowsCredential) {
                        $Params.Credential = $script:WindowsCredential
                    }

                    Test-WSMan @Params | Out-Null
                    $WinRM = $true
                }
                catch {}
            }

            if (-not ($Dns -and $WinRM)) {
                $Failures++
            }

            $Lines.Add(
                "  $HostName : DNS=$(if($Dns){'PASS'}else{'FAIL'}) | WinRM=$(if($WinRM){'PASS'}else{'FAIL'})"
            )
        }

        $Lines.Add("")
    }

    $Entries = @($script:PureArrayEntries)

    if ($Entries.Count -gt 0) {
        $Lines.Add("Arrays:")

        foreach ($Entry in $Entries) {
            $Endpoint = [string]$Entry.Endpoint
            $Dns = $false
            $Https = $false

            try {
                [System.Net.Dns]::GetHostAddresses($Endpoint) | Out-Null
                $Dns = $true
            }
            catch {}

            if ($Dns) {
                $Https = Test-TcpPort -ComputerName $Endpoint -Port 443
            }

            if (-not ($Dns -and $Https)) {
                $Failures++
            }

            $Lines.Add(
                "  $Endpoint : DNS=$(if($Dns){'PASS'}else{'FAIL'}) | TCP/443=$(if($Https){'PASS'}else{'FAIL'})"
            )
        }
    }

    $script:LastPreflightTime = Get-Date

    $Lines.Add("")

    $PreflightResult =
        if ($Failures -eq 0) {
            "RESULT: PASS"
        }
        else {
            "RESULT: $Failures failure(s)"
        }

    $Lines.Add($PreflightResult)

    [System.Windows.MessageBox]::Show(
        ($Lines -join [Environment]::NewLine),
        "Connectivity Preflight",
        "OK",
        $(if ($Failures -eq 0) { "Information" } else { "Warning" })
    ) | Out-Null

    Write-ToolLog `
        "Connectivity preflight completed with $Failures failure(s)."

    Update-SessionStateBanner

    Update-ValidationControls
}

function Open-CurrentToolLog {
    if (
        $script:LogPath -and
        (Test-Path $script:LogPath)
    ) {
        Start-Process -FilePath $script:LogPath
    }
    else {
        [System.Windows.MessageBox]::Show(
            "The current session log was not found.",
            "Log Not Found",
            "OK",
            "Information"
        ) | Out-Null
    }
}

function Get-ToolSignatureSummary {
    try {
        $Signature =
            Get-AuthenticodeSignature `
                -FilePath $PSCommandPath

        return "$($Signature.Status)"
    }
    catch {
        return "Unknown"
    }
}

function Sign-CurrentTool {
    $Certs = @(
        Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object {
                $_.NotAfter -gt (Get-Date)
            }
    )

    if ($Certs.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No valid code-signing certificate was found in Cert:\CurrentUser\My.`n`nThe tool was not signed.",
            "Code Signing Certificate Not Found",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    $Cert = $Certs |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    $Confirm =
        [System.Windows.MessageBox]::Show(
            "Sign the current tool with:`n`n$($Cert.Subject)`nExpires: $($Cert.NotAfter)`n`nAny future modification will invalidate the signature.",
            "Sign iSCSI Host Tool",
            "YesNo",
            "Warning"
        )

    if ($Confirm -ne "Yes") {
        return
    }

    try {
        $Result =
            Set-AuthenticodeSignature `
                -FilePath $PSCommandPath `
                -Certificate $Cert `
                -HashAlgorithm SHA256

        [System.Windows.MessageBox]::Show(
            "Signature status: $($Result.Status)",
            "Code Signing",
            "OK",
            $(if ($Result.Status -eq "Valid") { "Information" } else { "Warning" })
        ) | Out-Null
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "The tool could not be signed.`n`n$($_.Exception.Message)",
            "Code Signing Failed",
            "OK",
            "Error"
        ) | Out-Null
    }
}

function Show-AboutTool {
    $SDK =
        Get-Module -ListAvailable PureStoragePowerShellSDK2 |
            Sort-Object Version -Descending |
            Select-Object -First 1

    $SdkVersion =
        if ($SDK) {
            [string]$SDK.Version
        }
        else {
            "Not installed"
        }

    $Message = @"
iSCSI Host Tool

Version: $($script:ToolVersion)
PowerShell: $($PSVersionTable.PSVersion)
PureStoragePowerShellSDK2: $SdkVersion
Script signature: $(Get-ToolSignatureSummary)

Scope:
- Windows iSCSI / MPIO host preparation
- Pure host registration
- optional host-group membership

Out of scope:
- Pods
- Protection Groups
- volumes
- LUNs
- volume mappings
- Failover Cluster / CSV creation

Sign the tool now if a CurrentUser code-signing certificate is available?
"@

    $Choice =
        [System.Windows.MessageBox]::Show(
            $Message,
            "About iSCSI Host Tool",
            "YesNo",
            "Information"
        )

    if ($Choice -eq "Yes") {
        Sign-CurrentTool
    }
}

function Get-PureArrayDisplayIdentity {
    param(
        $DisplayRow,
        $PlanRow
    )

    foreach ($Object in @($DisplayRow, $PlanRow)) {
        if (-not $Object) {
            continue
        }

        foreach ($PropertyName in @(
            "ArrayEndpoint",
            "Endpoint",
            "ArrayAddress",
            "ArrayFqdn",
            "Fqdn",
            "Address"
        )) {
            if ($Object.PSObject.Properties.Name -contains $PropertyName) {
                $Value = [string]$Object.$PropertyName

                if (
                    -not [string]::IsNullOrWhiteSpace($Value) -and
                    $Value -notmatch '^PureStorage\.'
                ) {
                    return $Value
                }
            }
        }

        if ($Object.PSObject.Properties.Name -contains "Array") {
            $RawArray = $Object.Array

            if ($RawArray -is [string]) {
                $Value = [string]$RawArray

                if (
                    -not [string]::IsNullOrWhiteSpace($Value) -and
                    $Value -notmatch '^PureStorage\.'
                ) {
                    return $Value
                }
            }
        }
    }

    $RawPlanArray = $null

    if (
        $PlanRow -and
        $PlanRow.PSObject.Properties.Name -contains "Array"
    ) {
        $RawPlanArray = $PlanRow.Array
    }

    foreach ($Entry in @($script:PureArrayEntries)) {
        if (-not $Entry) {
            continue
        }

        $EntryEndpoint = ""

        foreach ($PropertyName in @(
            "Endpoint",
            "ArrayEndpoint",
            "Address",
            "Fqdn"
        )) {
            if (
                $Entry.PSObject.Properties.Name -contains $PropertyName -and
                -not [string]::IsNullOrWhiteSpace([string]$Entry.$PropertyName)
            ) {
                $EntryEndpoint = [string]$Entry.$PropertyName
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($EntryEndpoint)) {
            continue
        }

        foreach ($ConnectionProperty in @(
            "Array",
            "Connection",
            "Session",
            "Api",
            "Client"
        )) {
            if ($Entry.PSObject.Properties.Name -contains $ConnectionProperty) {
                $Candidate = $Entry.$ConnectionProperty

                if (
                    $null -ne $Candidate -and
                    $null -ne $RawPlanArray -and
                    [object]::ReferenceEquals($Candidate, $RawPlanArray)
                ) {
                    return $EntryEndpoint
                }
            }
        }
    }

    foreach ($Object in @($DisplayRow, $PlanRow)) {
        if (-not $Object) {
            continue
        }

        foreach ($PropertyName in @(
            "ArrayName",
            "Name"
        )) {
            if ($Object.PSObject.Properties.Name -contains $PropertyName) {
                $Value = [string]$Object.$PropertyName

                if (
                    -not [string]::IsNullOrWhiteSpace($Value) -and
                    $Value -notmatch '^PureStorage\.'
                ) {
                    return $Value
                }
            }
        }
    }

    return "(Unknown Array)"
}
function Show-PureChangePreviewDialog {
    try {
        $PreviewText =
            Get-PureChangePreview

        if ([string]::IsNullOrWhiteSpace([string]$PreviewText)) {
            $PreviewText =
                "No Pure Registration change preview is currently available."
        }

        $Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pure Registration Change Preview"
        Width="800"
        Height="650"
        MinWidth="650"
        MinHeight="450"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBox x:Name="PreviewTextBox"
                 Grid.Row="0"
                 IsReadOnly="True"
                 AcceptsReturn="True"
                 TextWrapping="NoWrap"
                 VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto"
                 FontFamily="Consolas"
                 Margin="0,0,0,10"/>

        <Button x:Name="CloseButton"
                Grid.Row="1"
                Content="OK"
                Width="100"
                Height="32"
                HorizontalAlignment="Right"
                IsDefault="True"
                IsCancel="True"/>
    </Grid>
</Window>
"@

        $Reader =
            New-Object System.Xml.XmlNodeReader ([xml]$Xaml)

        $Dialog =
            [Windows.Markup.XamlReader]::Load($Reader)

        if ($Window) {
            $Dialog.Owner = $Window
        }

        $PreviewTextBox =
            $Dialog.FindName("PreviewTextBox")

        $CloseButton =
            $Dialog.FindName("CloseButton")

        $PreviewTextBox.Text =
            [string]$PreviewText

        $CloseButton.Add_Click({
            $Dialog.Close()
        })

        $null =
            $Dialog.ShowDialog()
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Unable to display the change preview.`n`n$($_.Exception.Message)",
            "Pure Registration Change Preview",
            "OK",
            "Error"
        ) | Out-Null
    }
}
function Show-PureRegistrationConfirmation {
    param(
        [array]$Plan = $script:PurePlan
    )

    $PlanRows =
        @($Plan)

    if ($PlanRows.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No validated Pure registration plan is available.`n`nRun Validate / Dry Run again before Apply.",
            "Apply Pure Registration",
            "OK",
            "Warning"
        ) | Out-Null

        return $false
    }

    # Use the visible validation grid as the operator-facing display source.
    # The underlying Apply operation still uses $script:PurePlan.
    $GridRows = @()

    if ($PureResultsGrid) {
        foreach ($Item in @($PureResultsGrid.Items)) {
            if (
                $null -ne $Item -and
                $Item -ne [System.Windows.Data.CollectionView]::NewItemPlaceholder
            ) {
                $GridRows += $Item
            }
        }
    }

    if ($GridRows.Count -eq 0) {
        $GridRows =
            @($script:PureResults)
    }

    $Rows =
        @(
            $GridRows |
                ForEach-Object {
                    $HostValue =
                        if ($_.PSObject.Properties.Name -contains "Host") {
                            [string]$_.Host
                        }
                        else {
                            ""
                        }

                    $ArrayValue =
                        if ($_.PSObject.Properties.Name -contains "Array") {
                            [string]$_.Array
                        }
                        else {
                            ""
                        }

                    $StateValue =
                        if ($_.PSObject.Properties.Name -contains "State") {
                            [string]$_.State
                        }
                        else {
                            ""
                        }

                    $HostGroupValue =
                        if ($_.PSObject.Properties.Name -contains "HostGroup") {
                            [string]$_.HostGroup
                        }
                        else {
                            ""
                        }

                    $ActionValue =
                        if ($_.PSObject.Properties.Name -contains "Action") {
                            [string]$_.Action
                        }
                        else {
                            ""
                        }

                    if ([string]::IsNullOrWhiteSpace($HostGroupValue)) {
                        $HostGroupValue = "N/A"
                    }

                    if ([string]::IsNullOrWhiteSpace($ActionValue)) {
                        switch -Regex ($StateValue) {
                            '^CREATE$' {
                                $ActionValue = "Create host"
                                break
                            }
                            '^MATCH$' {
                                $ActionValue = "Reuse existing host"
                                break
                            }
                            default {
                                $ActionValue = $StateValue
                            }
                        }
                    }

                    [pscustomobject]@{
                        Host      = $HostValue
                        Array     = $ArrayValue
                        State     = $StateValue
                        HostGroup = $HostGroupValue
                        Action    = $ActionValue
                    }
                }
        )

    if ($Rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "The validated result grid is empty.`n`nRun Validate / Dry Run again before Apply.",
            "Apply Pure Registration",
            "OK",
            "Warning"
        ) | Out-Null

        return $false
    }

    $HostCount =
        @(
            $Rows.Host |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                } |
                Sort-Object -Unique
        ).Count

    $ArrayCount =
        @(
            $Rows.Array |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                } |
                Sort-Object -Unique
        ).Count

    $CreateCount =
        @($Rows | Where-Object { $_.State -eq "CREATE" }).Count

    $MatchCount =
        @($Rows | Where-Object { $_.State -eq "MATCH" }).Count

    Write-ToolLog `
        "Apply confirmation display rows: $($Rows.Count); hosts: $HostCount; arrays: $ArrayCount; CREATE: $CreateCount; MATCH: $MatchCount." `
        "INFO"

    $Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirm Pure Registration"
        Width="1100"
        Height="650"
        MinWidth="900"
        MinHeight="500"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0"
                   Text="Confirm Pure Registration"
                   FontSize="18"
                   FontWeight="SemiBold"
                   Margin="0,0,0,10"/>

        <TextBlock Grid.Row="1"
                   TextWrapping="Wrap"
                   Margin="0,0,0,10">
            <Run Text="Review every validated host action before continuing. "/>
            <Run Text="This tool does not create or connect volumes, LUNs, Pods, or Protection Groups."
                 FontWeight="SemiBold"/>
        </TextBlock>

        <DataGrid x:Name="PlanGrid"
                  Grid.Row="2"
                  AutoGenerateColumns="False"
                  IsReadOnly="True"
                  CanUserAddRows="False"
                  HeadersVisibility="Column"
                  Margin="0,0,0,10">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Host" Binding="{Binding Host}" Width="1.2*"/>
                <DataGridTextColumn Header="Array" Binding="{Binding Array}" Width="1.7*"/>
                <DataGridTextColumn Header="State" Binding="{Binding State}" Width="1.3*"/>
                <DataGridTextColumn Header="Host Group" Binding="{Binding HostGroup}" Width="1.5*"/>
                <DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="1.8*"/>
            </DataGrid.Columns>
        </DataGrid>

        <Border Grid.Row="3"
                BorderBrush="Gray"
                BorderThickness="1"
                Padding="10"
                Margin="0,0,0,10">
            <StackPanel>
                <TextBlock Text="$HostCount host(s) across $ArrayCount array(s); $($Rows.Count) validated row(s)"/>
                <TextBlock Text="Create: $CreateCount    Match/Reuse: $MatchCount"/>
                <TextBlock Text="Storage changes: Volumes=0 | LUNs=0 | Pods=0 | Protection Groups=0"
                           FontWeight="SemiBold"
                           Margin="0,4,0,0"/>
            </StackPanel>
        </Border>

        <StackPanel Grid.Row="4"
                    Orientation="Horizontal"
                    HorizontalAlignment="Right">
            <Button x:Name="CancelButton"
                    Content="Cancel"
                    Width="100"
                    Height="32"
                    Margin="0,0,8,0"
                    IsCancel="True"/>
            <Button x:Name="ApplyButton"
                    Content="Apply Registration"
                    Width="145"
                    Height="32"
                    IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

    try {
        $Reader =
            New-Object System.Xml.XmlNodeReader ([xml]$Xaml)

        $Dialog =
            [Windows.Markup.XamlReader]::Load($Reader)

        if ($Window) {
            $Dialog.Owner = $Window
        }

        $PlanGrid =
            $Dialog.FindName("PlanGrid")

        $ApplyButton =
            $Dialog.FindName("ApplyButton")

        $PlanGrid.ItemsSource =
            $Rows

        $script:PureRegistrationConfirmed =
            $false

        $ApplyButton.Add_Click({
            $script:PureRegistrationConfirmed = $true
            $Dialog.DialogResult = $true
            $Dialog.Close()
        })

        $null =
            $Dialog.ShowDialog()

        return [bool]$script:PureRegistrationConfirmed
    }
    catch {
        Write-ToolLog `
            "Confirm Pure Registration dialog failed: $($_.Exception.Message)" `
            "ERROR"

        [System.Windows.MessageBox]::Show(
            "Unable to display the registration confirmation dialog.`n`n$($_.Exception.Message)",
            "Confirmation Error",
            "OK",
            "Error"
        ) | Out-Null

        return $false
    }
}
function Get-EnhancedApplySummary {
    $Plans = @($script:PurePlan)

    $Hosts =
        @(
            $Plans |
                Select-Object -ExpandProperty Host -Unique
        ).Count

    $Arrays =
        @(
            $Plans |
                Select-Object -ExpandProperty Endpoint -Unique
        ).Count

    $CreateCount =
        @(
            $Plans |
                Where-Object {
                    $_.Check.State -eq "CREATE"
                }
        ).Count

    $ReuseCount =
        @(
            $Plans |
                Where-Object {
                    $_.Check.State -eq "MATCH"
                }
        ).Count

    $HostGroupCount = 0

    if (
        $script:PureGroupPlan -and
        $script:PureGroupPlan.Mode -ne "None"
    ) {
        $HostGroupCount =
            @(
                $Plans |
                    Where-Object {
                        $_.CurrentGroup -ine
                        $script:PureGroupPlan.Name
                    }
            ).Count
    }

    @"
APPLY SUMMARY

Arrays in scope:        $Arrays
Unique Windows hosts:   $Hosts

Create host objects:    $CreateCount
Reuse matching hosts:   $ReuseCount
Host-group assignments: $HostGroupCount

Volume changes:         0
LUN changes:            0
Pod changes:            0
Protection Group changes: 0

The current Dry Run must still be valid when Apply starts.
"@
}

function Test-PostApplyVerification {
    $Failures =
        New-Object System.Collections.Generic.List[string]

    foreach ($Plan in @($script:PurePlan)) {
        try {
            $Hosts =
                @(Get-LocalPureHosts $Plan.Array)

            $HostObject =
                $Hosts |
                    Where-Object {
                        $_.Name -ieq $Plan.Host
                    } |
                    Select-Object -First 1

            if (-not $HostObject) {
                $Failures.Add(
                    "$($Plan.Endpoint): host '$($Plan.Host)' is missing."
                )

                continue
            }

            $Iqns =
                @(Get-PureHostIqns $HostObject)

            if (
                @(
                    $Iqns |
                        Where-Object {
                            $_ -ieq $Plan.IQN
                        }
                ).Count -eq 0
            ) {
                $Failures.Add(
                    "$($Plan.Endpoint): host '$($Plan.Host)' does not contain required IQN '$($Plan.IQN)'."
                )
            }

            if ($Iqns.Count -gt 1) {
                $Failures.Add(
                    "$($Plan.Endpoint): host '$($Plan.Host)' contains unexpected additional IQN(s): $($Iqns -join ', ')."
                )
            }

            if (
                $script:PureGroupPlan -and
                $script:PureGroupPlan.Mode -ne "None"
            ) {
                $ActualGroup =
                    Get-PureHostGroupName $HostObject

                if (
                    $ActualGroup -ine
                    $script:PureGroupPlan.Name
                ) {
                    $Failures.Add(
                        "$($Plan.Endpoint): host '$($Plan.Host)' host group is '$ActualGroup'; expected '$($script:PureGroupPlan.Name)'."
                    )
                }
            }

            # Read connection state when the existing helper/cmdlet is
            # available. A nonzero count is reported for operator review;
            # this tool itself never creates those mappings.
            if (
                (Get-Command Get-PureHostConnections -ErrorAction SilentlyContinue) -and
                (Get-Command Get-Pfa2Connection -ErrorAction SilentlyContinue)
            ) {
                $Conn =
                    Get-PureHostConnections `
                        -Array $Plan.Array `
                        -HostObject $HostObject

                if (
                    $Conn.DirectConnections -gt 0 -or
                    $Conn.HostGroupConnections -gt 0
                ) {
                    $Failures.Add(
                        "$($Plan.Endpoint): '$($Plan.Host)' has storage connection(s) after Apply (Direct=$($Conn.DirectConnections), HostGroup=$($Conn.HostGroupConnections)). Verify these connections were pre-existing/intended."
                    )
                }
            }
        }
        catch {
            $Failures.Add(
                "$($Plan.Endpoint): verification error for '$($Plan.Host)': $($_.Exception.Message)"
            )
        }
    }

    if ($Failures.Count -eq 0) {
        $script:LastApplyVerificationTime = Get-Date

        $PureSummaryText.Text =
            "APPLY COMPLETE - VERIFIED. Host names, IQNs, and host-group membership match the plan."

        Set-GlobalStatus `
            "Apply complete - verified."

        Write-ToolLog `
            "Enhanced post-Apply verification passed."

        Update-SessionStateBanner

        return $true
    }

    $script:LastApplyVerificationTime = $null

    [System.Windows.MessageBox]::Show(
        "Post-Apply verification requires review:`n`n$($Failures -join "`n")",
        "Post-Apply Verification",
        "OK",
        "Warning"
    ) | Out-Null

    Write-ToolLog `
        "Post-Apply verification found issues: $($Failures -join '; ')" `
        "WARN"

    Update-SessionStateBanner

    return $false
}
function Export-AllToolArtifacts {
    try {
        $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $Root =
            Join-Path `
                $env:USERPROFILE `
                "Documents\iSCSI-Host-Tool-Exports"

        $ExportFolder =
            Join-Path `
                $Root `
                "Export-$Stamp"

        New-Item `
            -ItemType Directory `
            -Path $ExportFolder `
            -Force |
            Out-Null

        # Windows audit
        if ($script:WindowsResults.Count -gt 0) {
            $WindowsPath =
                Join-Path `
                    $ExportFolder `
                    "Windows-Audit-$Stamp.csv"

            @($script:WindowsResults) |
                Export-Csv `
                    -Path $WindowsPath `
                    -NoTypeInformation `
                    -Encoding UTF8
        }

        # Pure validation
        if ($script:PureResults.Count -gt 0) {
            $PurePath =
                Join-Path `
                    $ExportFolder `
                    "Pure-Validation-$Stamp.csv"

            @($script:PureResults) |
                Export-Csv `
                    -Path $PurePath `
                    -NoTypeInformation `
                    -Encoding UTF8
        }

        # iSCSI connection mappings / plan
        if ($script:IscsiConnectionResults -and
            $script:IscsiConnectionResults.Count -gt 0) {
            $IscsiPath =
                Join-Path $ExportFolder "iSCSI-Connection-Results-$Stamp.csv"

            @($script:IscsiConnectionResults) |
                Export-Csv `
                    -Path $IscsiPath `
                    -NoTypeInformation `
                    -Encoding UTF8
        }

        if ($script:IscsiConnectionPlan -and
            @($script:IscsiConnectionPlan).Count -gt 0) {
            $IscsiPlanPath =
                Join-Path $ExportFolder "iSCSI-Connection-Plan-$Stamp.csv"

            @($script:IscsiConnectionPlan) |
                Select-Object Host,SourceIP,Array,Endpoint,TargetIP,TargetPort,TargetIQN,PortalState,SessionState,Action,Persistent,Multipath,MinimumPaths,Blocking,Message |
                Export-Csv `
                    -Path $IscsiPlanPath `
                    -NoTypeInformation `
                    -Encoding UTF8

            Set-Content `
                -Path (Join-Path $ExportFolder "iSCSI-Change-Preview-$Stamp.txt") `
                -Value (Get-IscsiChangePreview) `
                -Encoding UTF8
        }

        # Change preview
        $PreviewPath =
            Join-Path `
                $ExportFolder `
                "Change-Preview-$Stamp.txt"

        $PreviewText =
            if (
                $script:PurePlan -and
                @($script:PurePlan).Count -gt 0
            ) {
                Get-PureChangePreview
            }
            else {
                "No Pure change preview is currently available."
            }

        Set-Content `
            -Path $PreviewPath `
            -Value $PreviewText `
            -Encoding UTF8

        # Session summary
        $SummaryPath =
            Join-Path `
                $ExportFolder `
                "Session-Summary-$Stamp.txt"

        $ArrayCount =
            @($script:PureArrayEntries).Count

        $ConnectedCount =
            @(
                $script:PureArrayEntries |
                    Where-Object {
                        $_.Status -eq "Connected"
                    }
            ).Count

        $Summary = @"
iSCSI Host Tool Export

Version: $($script:ToolVersion)
Exported: $(Get-Date)

Windows Audit Complete: $($script:WindowsAuditComplete)
Last Windows Audit: $($script:LastWindowsAuditTime)

Arrays: $ConnectedCount/$ArrayCount Connected

Pure Validation Ready: $($script:PureValidationReady)
Last Pure Validation: $($script:LastPureValidationTime)

Last Apply Verification: $($script:LastApplyVerificationTime)

iSCSI Validation Ready: $($script:IscsiValidationReady)
Last iSCSI Preflight: $($script:LastIscsiPreflightTime)
Last iSCSI Validation: $($script:LastIscsiValidationTime)
Last iSCSI Apply Verification: $($script:LastIscsiApplyVerificationTime)
iSCSI Mapping Count: $(@($script:IscsiConnectionResults).Count)

Storage Safety Boundary:
Volume changes: 0
LUN changes: 0
Pod changes: 0
Protection Group changes: 0
"@

        Set-Content `
            -Path $SummaryPath `
            -Value $Summary `
            -Encoding UTF8

        # Current log
        if (
            $script:LogPath -and
            (Test-Path $script:LogPath)
        ) {
            Copy-Item `
                -Path $script:LogPath `
                -Destination (
                    Join-Path `
                        $ExportFolder `
                        "Session-Log-$Stamp.log"
                ) `
                -Force
        }

        Write-ToolLog `
            "Exported complete session package to $ExportFolder." `
            "INFO"

        [System.Windows.MessageBox]::Show(
            "Export completed.`n`n$ExportFolder",
            "Export All",
            "OK",
            "Information"
        ) | Out-Null

        Start-Process `
            -FilePath $ExportFolder
    }
    catch {
        Write-ToolLog `
            "Export All failed: $($_.Exception.Message)" `
            "ERROR"

        [System.Windows.MessageBox]::Show(
            "Export All failed.`n`n$($_.Exception.Message)",
            "Export Failed",
            "OK",
            "Error"
        ) | Out-Null
    }
}

function Reset-ToolSession {
    $Confirm =
        [System.Windows.MessageBox]::Show(
            "Reset the current working session?`n`nThis clears:`n- Windows audit results/state`n- in-memory Windows credential`n- Pure validation results/plan`n- iSCSI connection mappings/plan/readiness`n- Apply readiness`n`nReset Session does NOT disconnect active Windows iSCSI sessions.`nActive array connections remain connected until the application closes.`nSaved encrypted array definitions are retained.",
            "Reset Session",
            "YesNo",
            "Warning"
        )

    if ($Confirm -ne "Yes") {
        return
    }

    $script:WindowsCredential = $null
    $script:WindowsAuditComplete = $false
    $script:WindowsAuditHostSignature = ""
    $script:LastWindowsAuditTime = $null

    if ($script:WindowsResults) {
        $script:WindowsResults.Clear()
    }

    $script:PureValidationReady = $false
    $script:LastPureValidationTime = $null
    $script:LastApplyVerificationTime = $null
    $script:PureValidationReason = "Not validated"
    $script:PurePlan = @()
    $script:PureGroupPlan = $null

    if ($script:PureResults) {
        $script:PureResults.Clear()
    }

    $script:IscsiValidationReady = $false
    $script:IscsiValidationReason = "Not validated"
    $script:IscsiConnectionPlan = @()
    $script:LastIscsiPreflightTime = $null
    $script:LastIscsiValidationTime = $null
    $script:LastIscsiApplyVerificationTime = $null
    $script:IscsiInputSignature = ""

    if ($script:IscsiConnectionResults) {
        $script:IscsiConnectionResults.Clear()
    }

    if ($IscsiSummaryText) {
        $IscsiSummaryText.Text =
            "Session reset. Active Windows iSCSI sessions were not disconnected."
    }

    # Keep active SDK connections alive until application close.
    # Clear only stored credential references.
    if ($script:PureCredentials) {
        $script:PureCredentials.Clear()
    }

    if ($ValidatePureButton) {
        $ValidatePureButton.IsEnabled = $false
    }

    if ($ApplyPureButton) {
        $ApplyPureButton.IsEnabled = $false
    }

    if ($ReviewConflictButton) {
        $ReviewConflictButton.IsEnabled = $false
    }

    if ($PureSummaryText) {
        $PureSummaryText.Text =
            "Session reset. Arrays remain connected. Re-audit Windows hosts before validation."
    }

    Set-GlobalStatus `
        "Session reset. Array connections preserved."

    Write-ToolLog `
        "Session reset. Windows audit and Pure validation state cleared; active array connections preserved until application close." `
        "CHANGE"

    Update-SessionStateBanner
    Update-ValidationControls
    Update-ConflictReviewControls
}
# ------------------------------------------------------------
# iSCSI Connections phase
# ------------------------------------------------------------

function Get-IscsiHostChoices {
    @(
        $script:WindowsResults |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.Host)
            } |
            Sort-Object Host -Unique |
            ForEach-Object {
                [pscustomobject]@{
                    Host    = [string]$_.Host
                    Display = [string]$_.Host
                }
            }
    )
}

function Get-IscsiArrayChoices {
    @(
        $script:PureArrayEntries |
            Where-Object {
                [string]$_.Status -eq "Connected"
            } |
            ForEach-Object {
                $Identity =
                    if (-not [string]::IsNullOrWhiteSpace([string]$_.ArrayName)) {
                        [string]$_.ArrayName
                    }
                    else {
                        [string]$_.Endpoint
                    }

                [pscustomobject]@{
                    Identity = $Identity
                    Endpoint = [string]$_.Endpoint
                    Display  = $Identity
                }
            } |
            Sort-Object Display
    )
}

function Get-PureIscsiTargetChoices {
    param([string]$ArrayIdentity)

    $Context = Get-IscsiArrayContext -ArrayIdentity $ArrayIdentity

    if (-not $Context) {
        return @()
    }

    if (-not (Get-Command Get-Pfa2Port -ErrorAction SilentlyContinue)) {
        throw "PureStoragePowerShellSDK2 does not expose Get-Pfa2Port."
    }

    $Rows = @()

    foreach ($Port in @(Get-Pfa2Port -Array $Context.Array -ErrorAction Stop)) {
        $Portal = ([string]$Port.Portal).Trim()
        $Iqn = ([string]$Port.Iqn).Trim()

        if ([string]::IsNullOrWhiteSpace($Portal) -or
            [string]::IsNullOrWhiteSpace($Iqn)) {
            continue
        }

        $Address = $Portal
        $PortNumber = 3260

        if ($Portal -match '^\[(.+)\]:(\d+)$') {
            $Address = [string]$Matches[1]
            $PortNumber = [int]$Matches[2]
        }
        elseif ($Portal -match '^(.+):(\d+)$') {
            $Address = [string]$Matches[1]
            $PortNumber = [int]$Matches[2]
        }

        $PortName = [string]$Port.Name

        $Display =
            if (-not [string]::IsNullOrWhiteSpace($PortName)) {
                "$Address - $PortName"
            }
            else {
                $Address
            }

        $Rows += [pscustomobject]@{
            IPAddress  = $Address
            PortNumber = $PortNumber
            IQN        = $Iqn
            PortName   = $PortName
            Display    = $Display
        }
    }

    @(
        $Rows |
            Sort-Object IPAddress,PortName -Unique
    )
}

function Refresh-IscsiHostChoices {
    if (-not $IscsiHostComboBox) {
        return
    }

    $Previous = [string]$IscsiHostComboBox.SelectedValue
    $Choices = @(Get-IscsiHostChoices)
    $IscsiHostComboBox.ItemsSource = $Choices

    if ($Previous) {
        $IscsiHostComboBox.SelectedValue = $Previous
    }

    if (-not $IscsiHostComboBox.SelectedItem -and
        $Choices.Count -gt 0) {
        $IscsiHostComboBox.SelectedIndex = 0
    }
}

function Refresh-IscsiArrayChoices {
    if (-not $IscsiArrayComboBox) {
        return
    }

    $Previous = [string]$IscsiArrayComboBox.SelectedValue
    $Choices = @(Get-IscsiArrayChoices)
    $IscsiArrayComboBox.ItemsSource = $Choices

    if ($Previous) {
        $IscsiArrayComboBox.SelectedValue = $Previous
    }

    if (-not $IscsiArrayComboBox.SelectedItem -and
        $Choices.Count -gt 0) {
        $IscsiArrayComboBox.SelectedIndex = 0
    }
}

function Refresh-IscsiSourceChoices {
    if (-not $IscsiSourceComboBox) {
        return
    }

    $IscsiSourceComboBox.ItemsSource = $null
    $HostName = [string]$IscsiHostComboBox.SelectedValue

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return
    }

    try {
        Set-GlobalStatus "Discovering enabled IPv4 interfaces on $HostName..."

        $Inventory = Get-IscsiHostInventory -HostName $HostName

        $Choices = @(
            $Inventory.SourceAddresses |
                Sort-Object InterfaceIndex,IPAddress |
                ForEach-Object {
                    [pscustomobject]@{
                        IPAddress      = [string]$_.IPAddress
                        PrefixLength   = [int]$_.PrefixLength
                        InterfaceAlias = [string]$_.InterfaceAlias
                        InterfaceIndex = [int]$_.InterfaceIndex
                        Display        = "{0} - {1} - Up" -f
                            [string]$_.IPAddress,
                            [string]$_.InterfaceAlias
                    }
                }
        )

        $IscsiSourceComboBox.ItemsSource = $Choices

        if ($Choices.Count -gt 0) {
            $IscsiSourceComboBox.SelectedIndex = 0
        }

        Set-GlobalStatus "Discovered $($Choices.Count) enabled IPv4 interface(s) on $HostName."
    }
    catch {
        Write-ToolLog `
            "Failed to discover iSCSI source choices for ${HostName}: $($_.Exception.Message)" `
            "ERROR"

        [System.Windows.MessageBox]::Show(
            "Unable to discover enabled IPv4 interfaces on ${HostName}.`n`n$($_.Exception.Message)",
            "Source NIC Discovery",
            "OK",
            "Error"
        ) | Out-Null
    }
}

function Refresh-IscsiTargetChoices {
    if (-not $IscsiTargetComboBox) {
        return
    }

    $IscsiTargetComboBox.ItemsSource = $null
    $IscsiTargetIqnTextBox.Text = ""

    $ArrayIdentity = [string]$IscsiArrayComboBox.SelectedValue

    if ([string]::IsNullOrWhiteSpace($ArrayIdentity)) {
        return
    }

    try {
        Set-GlobalStatus "Discovering Pure iSCSI target ports on $ArrayIdentity..."

        $Choices = @(
            Get-PureIscsiTargetChoices -ArrayIdentity $ArrayIdentity
        )

        $IscsiTargetComboBox.ItemsSource = $Choices

        if ($Choices.Count -gt 0) {
            $IscsiTargetComboBox.SelectedIndex = 0
        }

        Set-GlobalStatus "Discovered $($Choices.Count) iSCSI target port(s) on $ArrayIdentity."
    }
    catch {
        Write-ToolLog `
            "Failed to discover iSCSI target choices for ${ArrayIdentity}: $($_.Exception.Message)" `
            "ERROR"

        [System.Windows.MessageBox]::Show(
            "Unable to discover Pure iSCSI target ports on ${ArrayIdentity}.`n`n$($_.Exception.Message)",
            "Pure Target Discovery",
            "OK",
            "Error"
        ) | Out-Null
    }
}

function Update-IscsiTargetIqnPreview {
    if (-not $IscsiTargetIqnTextBox) {
        return
    }

    if ($IscsiTargetComboBox.SelectedItem) {
        $IscsiTargetIqnTextBox.Text =
            [string]$IscsiTargetComboBox.SelectedItem.IQN
    }
    else {
        $IscsiTargetIqnTextBox.Text = ""
    }
}

function Refresh-IscsiSmartChoices {
    Refresh-IscsiHostChoices
    Refresh-IscsiArrayChoices
    Refresh-IscsiSourceChoices
    Refresh-IscsiTargetChoices
    Update-IscsiTargetIqnPreview
}

function Test-IPv4SameSubnet {
    param(
        [string]$SourceIP,
        [int]$PrefixLength,
        [string]$TargetIP
    )

    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
        return $false
    }

    try {
        $Source = [System.Net.IPAddress]::Parse($SourceIP)
        $Target = [System.Net.IPAddress]::Parse($TargetIP)

        if ($Source.AddressFamily -ne
            [System.Net.Sockets.AddressFamily]::InterNetwork -or
            $Target.AddressFamily -ne
            [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $false
        }

        $SourceBytes = $Source.GetAddressBytes()
        $TargetBytes = $Target.GetAddressBytes()
        $BitsRemaining = $PrefixLength

        for ($Index = 0; $Index -lt 4; $Index++) {
            $Mask =
                if ($BitsRemaining -ge 8) {
                    255
                }
                elseif ($BitsRemaining -le 0) {
                    0
                }
                else {
                    256 - [int][math]::Pow(2,(8 - $BitsRemaining))
                }

            if (($SourceBytes[$Index] -band $Mask) -ne
                ($TargetBytes[$Index] -band $Mask)) {
                return $false
            }

            $BitsRemaining -= 8
        }

        $true
    }
    catch {
        $false
    }
}

function Build-IscsiRecommendedPlan {
    $CurrentHosts = @(Get-HostList $HostTextBox.Text)
    $CurrentSignature =
        (($CurrentHosts |
            ForEach-Object { $_.ToLowerInvariant() } |
            Sort-Object) -join "|")

    $AuditCurrent = (
        $script:WindowsAuditComplete -and
        -not [string]::IsNullOrWhiteSpace(
            $script:WindowsAuditHostSignature
        ) -and
        $script:WindowsAuditHostSignature -eq $CurrentSignature
    )

    if (-not $AuditCurrent) {
        [System.Windows.MessageBox]::Show(
            "Run a current Windows Host audit before building a recommended iSCSI plan.",
            "Windows Audit Required",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    $ConnectedArrays = @(
        Get-IscsiArrayChoices
    )

    if ($ConnectedArrays.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Connect at least one Pure array before building a recommended iSCSI plan.",
            "Pure Array Required",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    if ($script:IscsiConnectionResults.Count -gt 0) {
        $Replace = [System.Windows.MessageBox]::Show(
            "Replace the current iSCSI mapping plan with a newly discovered recommended plan?`n`nThis only changes the in-memory plan. It does not create portals or sessions.",
            "Rebuild Recommended Plan",
            "YesNo",
            "Question"
        )

        if ($Replace -ne "Yes") {
            return
        }
    }

    Set-BusyState $true

    try {
        Write-ToolLog `
            "ISCSI PLANNER START - hosts=$($CurrentHosts.Count) arrays=$($ConnectedArrays.Count)." `
            "INFO"

        Set-GlobalStatus "Discovering Pure iSCSI target topology..."

        $TargetCatalog = @()

        foreach ($ArrayChoice in $ConnectedArrays) {
            $ArrayIdentity = [string]$ArrayChoice.Identity
            $Targets = @(
                Get-PureIscsiTargetChoices `
                    -ArrayIdentity $ArrayIdentity
            )

            foreach ($Target in $Targets) {
                $TargetCatalog += [pscustomobject]@{
                    Array      = $ArrayIdentity
                    TargetIP   = [string]$Target.IPAddress
                    PortNumber = [int]$Target.PortNumber
                    PortName   = [string]$Target.PortName
                    IQN        = [string]$Target.IQN
                }
            }
        }

        if ($TargetCatalog.Count -eq 0) {
            throw "No Pure iSCSI target ports were discovered on the connected arrays."
        }

        $ProposedRows = @()
        $ExcludedSources = New-Object System.Collections.Generic.List[string]
        $HostPlanCounts = @{}

        foreach ($HostName in $CurrentHosts) {
            Set-GlobalStatus "Discovering iSCSI topology on $HostName..."

            $Inventory = Get-IscsiHostInventory -HostName $HostName

            foreach ($Source in @($Inventory.SourceAddresses)) {
                $SourceIP = [string]$Source.IPAddress
                $PrefixLength = [int]$Source.PrefixLength
                $MatchingTargets = @(
                    $TargetCatalog |
                        Where-Object {
                            Test-IPv4SameSubnet `
                                -SourceIP $SourceIP `
                                -PrefixLength $PrefixLength `
                                -TargetIP ([string]$_.TargetIP)
                        }
                )

                if ($MatchingTargets.Count -eq 0) {
                    $ExcludedSources.Add(
                        "$HostName $SourceIP ($([string]$Source.InterfaceAlias))"
                    )
                    continue
                }

                foreach ($Target in $MatchingTargets) {
                    $Row = New-IscsiMappingRow `
                        -HostName $HostName `
                        -SourceIP $SourceIP `
                        -ArrayName ([string]$Target.Array) `
                        -TargetIP ([string]$Target.TargetIP)

                    $Row.TargetIQN = [string]$Target.IQN
                    $Row.Action = "PROPOSED"
                    $Row.Result =
                        "RECOMMENDED - same subnet; target $([string]$Target.PortName)"

                    $ProposedRows += $Row
                }
            }

            $HostPlanCounts[$HostName] = @(
                $ProposedRows |
                    Where-Object {
                        [string]$_.Host -ieq $HostName
                    }
            ).Count
        }

        $UniqueRows = @(
            $ProposedRows |
                Group-Object {
                    "{0}|{1}|{2}|{3}" -f
                        ([string]$_.Host).ToLowerInvariant(),
                        ([string]$_.SourceIP).ToLowerInvariant(),
                        ([string]$_.Array).ToLowerInvariant(),
                        ([string]$_.TargetIP).ToLowerInvariant()
                } |
                ForEach-Object {
                    $_.Group | Select-Object -First 1
                } |
                Sort-Object Host,SourceIP,Array,TargetIP
        )

        if ($UniqueRows.Count -eq 0) {
            throw "No same-subnet host-to-Pure iSCSI mappings were discovered. Use Manual Mapping for routed or non-standard topologies."
        }

        $script:IscsiConnectionResults.Clear()

        foreach ($Row in $UniqueRows) {
            $script:IscsiConnectionResults.Add($Row)
        }

        $OverLimitHosts = @(
            $CurrentHosts |
                Where-Object {
                    [int]$HostPlanCounts[$_] -gt
                    $script:WindowsMpioMaxPathsPerDevice
                }
        )

        foreach ($HostName in $OverLimitHosts) {
            foreach ($Row in @(
                $script:IscsiConnectionResults |
                    Where-Object {
                        [string]$_.Host -ieq $HostName
                    }
            )) {
                $Row.Result =
                    "REVIEW - proposed mapping count exceeds Windows 32-path maximum"
            }
        }

        Invalidate-IscsiValidationState `
            -Reason "Recommended plan rebuilt"

        $Summary =
            "Recommended plan built: $($UniqueRows.Count) mapping(s) across $($CurrentHosts.Count) host(s) and $($ConnectedArrays.Count) connected array(s). Same-subnet Pure targets only; $($ExcludedSources.Count) non-matching host interface(s) excluded."

        if ($OverLimitHosts.Count -gt 0) {
            $Summary +=
                " REVIEW REQUIRED: " +
                ($OverLimitHosts -join ", ") +
                " exceed the 32-path planning limit."
        }

        $IscsiSummaryText.Text = $Summary
        Set-GlobalStatus $Summary

        Write-ToolLog `
            "ISCSI PLANNER COMPLETE - mappings=$($UniqueRows.Count) excludedSources=$($ExcludedSources.Count) overLimitHosts=$($OverLimitHosts.Count)." `
            "INFO"

        if ($ExcludedSources.Count -gt 0) {
            Write-ToolLog `
                ("ISCSI PLANNER excluded non-matching interfaces: " +
                 ($ExcludedSources -join "; ")) `
                "INFO"
        }
    }
    catch {
        Write-ToolLog `
            "ISCSI PLANNER FAILED: $($_.Exception.Message)" `
            "ERROR"

        Set-GlobalStatus "Recommended plan build failed."

        [System.Windows.MessageBox]::Show(
            "Unable to build the recommended iSCSI plan.`n`n$($_.Exception.Message)",
            "Recommended Plan",
            "OK",
            "Error"
        ) | Out-Null
    }
    finally {
        Set-BusyState $false
        Update-IscsiControls
        Update-SessionStateBanner
    }
}

function New-IscsiMappingRow {
    param(
        [string]$HostName = "",
        [string]$SourceIP = "",
        [string]$ArrayName = "",
        [string]$TargetIP = ""
    )

    [pscustomobject]@{
        Include      = $true
        Host         = $HostName
        SourceIP     = $SourceIP
        Array        = $ArrayName
        TargetIP     = $TargetIP
        TargetIQN    = ""
        TCP3260      = ""
        PortalState  = ""
        SessionState = ""
        Action       = ""
        Result       = ""
    }
}

function Get-IscsiSelectedMappings {
    if (-not $script:IscsiConnectionResults) {
        return @()
    }

    @(
        $script:IscsiConnectionResults |
            Where-Object { $_.Include -eq $true }
    )
}

function Get-IscsiInputSignature {
    $Rows = @(
        Get-IscsiSelectedMappings |
            ForEach-Object {
                "{0}|{1}|{2}|{3}" -f
                    ([string]$_.Host).Trim().ToLowerInvariant(),
                    ([string]$_.SourceIP).Trim().ToLowerInvariant(),
                    ([string]$_.Array).Trim().ToLowerInvariant(),
                    ([string]$_.TargetIP).Trim().ToLowerInvariant()
            } |
            Sort-Object
    )

    $Persistent = [bool]$IscsiPersistentCheckBox.IsChecked
    $Multipath = [bool]$IscsiMultipathCheckBox.IsChecked
    $Minimum = ([string]$IscsiMinimumPathsTextBox.Text).Trim()

    (($Rows -join ";") + "|persistent=$Persistent|multipath=$Multipath|min=$Minimum")
}

function Invalidate-IscsiValidationState {
    param([string]$Reason = "iSCSI inputs changed")

    $script:IscsiValidationReady = $false
    $script:IscsiValidationReason = "STALE"
    $script:IscsiConnectionPlan = @()
    $script:LastIscsiValidationTime = $null
    $script:LastIscsiApplyVerificationTime = $null
    $script:IscsiInputSignature = ""

    if ($IscsiApplyButton) {
        $IscsiApplyButton.IsEnabled = $false
    }

    if ($IscsiPreviewButton) {
        $IscsiPreviewButton.IsEnabled = $false
    }

    if ($IscsiSummaryText) {
        $IscsiSummaryText.Text = "iSCSI validation is stale. Run Validate / Dry Run again."
    }

    Write-ToolLog "iSCSI validation invalidated: $Reason." "INFO"
    Update-IscsiControls
}

function Update-IscsiControls {
    if (-not $IscsiValidateButton) {
        return
    }

    try {
        $Busy = [bool]$script:IsBusy
        $Mappings = @(Get-IscsiSelectedMappings)
        $CurrentHosts = @(Get-HostList $HostTextBox.Text)
        $CurrentSignature = (($CurrentHosts | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join "|")

        $AuditCurrent = (
            $script:WindowsAuditComplete -and
            -not [string]::IsNullOrWhiteSpace($script:WindowsAuditHostSignature) -and
            $script:WindowsAuditHostSignature -eq $CurrentSignature
        )

        $ConnectedArrayCount = @(
            $script:PureArrayEntries |
                Where-Object { $_.Status -eq "Connected" }
        ).Count

        $CanValidate = (
            -not $Busy -and
            $AuditCurrent -and
            $Mappings.Count -gt 0 -and
            $ConnectedArrayCount -gt 0
        )

        $IscsiValidateButton.IsEnabled = $CanValidate
        $IscsiPreviewButton.IsEnabled = (
            -not $Busy -and
            @($script:IscsiConnectionPlan).Count -gt 0
        )
        $IscsiApplyButton.IsEnabled = (
            -not $Busy -and
            $script:IscsiValidationReady
        )

        if ($CanValidate) {
            $IscsiValidateButton.ToolTip =
                "Read-only preflight and desired-state comparison. No portals or sessions are created."
        }
        else {
            $Reasons = @()
            if ($Busy) { $Reasons += "Busy" }
            if (-not $AuditCurrent) { $Reasons += "Windows audit not current" }
            if ($Mappings.Count -eq 0) { $Reasons += "No mappings" }
            if ($ConnectedArrayCount -eq 0) { $Reasons += "No connected arrays" }

            $IscsiValidateButton.ToolTip =
                "Validate / Dry Run unavailable: " + ($Reasons -join "; ")
        }
    }
    catch {
        $IscsiValidateButton.IsEnabled = $false
        Write-ToolLog "Update-IscsiControls failed: $($_.Exception.Message)" "ERROR"
    }
}

function Get-IscsiArrayContext {
    param([string]$ArrayIdentity)

    $Name = ([string]$ArrayIdentity).Trim()

    foreach ($Entry in @($script:PureArrayEntries)) {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            continue
        }

        $MatchesEntry = (
            [string]$Entry.Endpoint -ieq $Name -or
            [string]$Entry.ArrayName -ieq $Name
        )

        if (-not $MatchesEntry) {
            continue
        }

        if ([string]$Entry.Status -ne "Connected") {
            return $null
        }

        $Endpoint = [string]$Entry.Endpoint

        if (-not $script:PureArrays.ContainsKey($Endpoint)) {
            return $null
        }

        return [pscustomobject]@{
            Endpoint  = $Endpoint
            ArrayName = [string]$Entry.ArrayName
            Array     = $script:PureArrays[$Endpoint]
        }
    }

    $null
}

function Resolve-PureIscsiTargetIqn {
    param(
        $ArrayContext,
        [string]$TargetIP
    )

    if (-not $ArrayContext -or -not $ArrayContext.Array) {
        throw "Array context is not connected."
    }

    if (-not (Get-Command Get-Pfa2Port -ErrorAction SilentlyContinue)) {
        throw "PureStoragePowerShellSDK2 does not expose Get-Pfa2Port. Update the SDK before using iSCSI Connections."
    }

    $Target = ([string]$TargetIP).Trim()
    $FoundIqns = @()

    foreach ($Port in @(Get-Pfa2Port -Array $ArrayContext.Array -ErrorAction Stop)) {
        $Portal = ([string]$Port.Portal).Trim()
        $Iqn = ([string]$Port.Iqn).Trim()

        if ([string]::IsNullOrWhiteSpace($Portal) -or
            [string]::IsNullOrWhiteSpace($Iqn)) {
            continue
        }

        $PortalAddress = $Portal

        if ($Portal -match '^\[(.+)\]:(\d+)$') {
            $PortalAddress = [string]$Matches[1]
        }
        elseif ($Portal -match '^(.+):(\d+)$') {
            $PortalAddress = [string]$Matches[1]
        }

        if ($PortalAddress -ieq $Target) {
            $FoundIqns += $Iqn
        }
    }

    $Unique = @($FoundIqns | Sort-Object -Unique)

    if ($Unique.Count -eq 0) {
        throw "Target IP $Target was not found as an iSCSI portal on array '$($ArrayContext.ArrayName)'."
    }

    if ($Unique.Count -gt 1) {
        throw "Target IP $Target resolved to multiple target IQNs on array '$($ArrayContext.ArrayName)'."
    }

    [string]$Unique[0]
}

function Get-IscsiHostInventory {
    param([string]$HostName)

    Invoke-HostCommand -ComputerName $HostName -ScriptBlock {
        $Out = [ordered]@{
            ServiceRunning  = $false
            MPIOInstalled   = $false
            PureDSM         = $false
            SourceAddresses = @()
            Portals         = @()
            Targets         = @()
            Sessions        = @()
            Connections     = @()
        }

        try {
            $Svc = Get-Service -Name MSiSCSI -ErrorAction Stop
            $Out.ServiceRunning = ($Svc.Status -eq "Running")
        }
        catch {}

        try {
            $Feature = Get-WindowsFeature -Name Multipath-IO -ErrorAction Stop
            $Out.MPIOInstalled = [bool]$Feature.Installed
        }
        catch {}

        try {
            Import-Module MPIO -ErrorAction SilentlyContinue
            $Pure = @(
                Get-MSDSMSupportedHW -ErrorAction Stop |
                    Where-Object {
                        ([string]$_.VendorId).Trim() -eq "PURE" -and
                        ([string]$_.ProductId).Trim() -eq "FlashArray"
                    }
            )
            $Out.PureDSM = ($Pure.Count -gt 0)
        }
        catch {}

        try {
            foreach ($Ip in @(
                Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object {
                        $_.IPAddress -and
                        $_.IPAddress -notlike "169.254.*" -and
                        $_.IPAddress -ne "127.0.0.1"
                    }
            )) {
                $Adapter = Get-NetAdapter -InterfaceIndex $Ip.InterfaceIndex -ErrorAction SilentlyContinue

                if ($Adapter -and $Adapter.Status -eq "Up") {
                    $Out.SourceAddresses += [pscustomobject]@{
                        IPAddress      = [string]$Ip.IPAddress
                        PrefixLength   = [int]$Ip.PrefixLength
                        InterfaceAlias = [string]$Ip.InterfaceAlias
                        InterfaceIndex = [int]$Ip.InterfaceIndex
                        Status         = [string]$Adapter.Status
                    }
                }
            }
        }
        catch {}

        try {
            $Out.Portals = @(
                Get-IscsiTargetPortal -ErrorAction Stop |
                    Select-Object TargetPortalAddress,TargetPortalPortNumber,InitiatorPortalAddress
            )
        }
        catch {}

        try {
            $Out.Targets = @(
                Get-IscsiTarget -ErrorAction Stop |
                    Select-Object NodeAddress,IsConnected
            )
        }
        catch {}

        try {
            $Out.Sessions = @(
                Get-IscsiSession -ErrorAction Stop |
                    Select-Object TargetNodeAddress,InitiatorNodeAddress,IsConnected,IsPersistent,NumberOfConnections,InitiatorPortalAddress,TargetPortalAddress
            )
        }
        catch {}

        try {
            $Out.Connections = @(
                Get-IscsiConnection -ErrorAction Stop |
                    Select-Object ConnectionIdentifier,InitiatorAddress,InitiatorPortNumber,TargetAddress,TargetPortNumber
            )
        }
        catch {}

        [pscustomobject]$Out
    }
}

function Test-IscsiSourceBoundTcp {
    param(
        [string]$HostName,
        [string]$SourceIP,
        [string]$TargetIP,
        [int]$Port = 3260,
        [int]$TimeoutMilliseconds = 3000
    )

    $Result = Invoke-HostCommand -ComputerName $HostName -ArgumentList @(
        $SourceIP,
        $TargetIP,
        $Port,
        $TimeoutMilliseconds
    ) -ScriptBlock {
        param($LocalAddress,$RemoteAddress,$RemotePort,$Timeout)

        $Socket = $null

        try {
            $LocalIp = [System.Net.IPAddress]::Parse($LocalAddress)
            $RemoteIp = [System.Net.IPAddress]::Parse($RemoteAddress)

            if ($LocalIp.AddressFamily -ne $RemoteIp.AddressFamily) {
                return $false
            }

            $Socket = New-Object System.Net.Sockets.Socket(
                $LocalIp.AddressFamily,
                [System.Net.Sockets.SocketType]::Stream,
                [System.Net.Sockets.ProtocolType]::Tcp
            )

            $Socket.Bind(
                (New-Object System.Net.IPEndPoint($LocalIp,0))
            )

            $Async = $Socket.BeginConnect(
                $RemoteIp,
                [int]$RemotePort,
                $null,
                $null
            )

            if (-not $Async.AsyncWaitHandle.WaitOne([int]$Timeout,$false)) {
                return $false
            }

            $Socket.EndConnect($Async)
            [bool]$Socket.Connected
        }
        catch {
            $false
        }
        finally {
            if ($Socket) {
                try { $Socket.Close() } catch {}
            }
        }
    }

    [bool]$Result
}

function Get-PureRecommendedMpioExpectation {
    param([int]$PathCount)

    if ($PathCount -gt $script:WindowsMpioMaxPathsPerDevice) {
        return [pscustomobject]@{
            Expected = "FAIL - Windows supports no more than 32 MPIO paths per device"
            HardFail = $true
        }
    }

    if ($PathCount -gt 10) {
        return [pscustomobject]@{
            Expected = "LQD expected for 11-32 paths"
            HardFail = $false
        }
    }

    if ($PathCount -gt 0) {
        return [pscustomobject]@{
            Expected = "RR or LQD valid; RR preferred for 1-10 paths"
            HardFail = $false
        }
    }

    [pscustomobject]@{
        Expected = "Path count unavailable"
        HardFail = $false
    }
}

function Invoke-IscsiConnectionPreflight {
    if ($IscsiMappingGrid) {
        $null = $IscsiMappingGrid.CommitEdit(
            [System.Windows.Controls.DataGridEditingUnit]::Cell,
            $true
        )
        $null = $IscsiMappingGrid.CommitEdit(
            [System.Windows.Controls.DataGridEditingUnit]::Row,
            $true
        )
    }

    $Mappings = @(Get-IscsiSelectedMappings)

    if ($Mappings.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Add and enable at least one iSCSI mapping first.",
            "No iSCSI Mappings",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    $MinimumPaths = 0
    $MinimumText = ([string]$IscsiMinimumPathsTextBox.Text).Trim()

    if ($MinimumText) {
        $ParsedMinimum = 0

        if (-not [int]::TryParse($MinimumText,[ref]$ParsedMinimum) -or
            $ParsedMinimum -lt 1 -or
            $ParsedMinimum -gt 32) {
            [System.Windows.MessageBox]::Show(
                "Expected minimum paths must be blank or an integer from 1 through 32.",
                "Invalid Minimum Path Count",
                "OK",
                "Warning"
            ) | Out-Null
            return
        }

        $MinimumPaths = $ParsedMinimum
    }

    $HostsInScope = @(Get-HostList $HostTextBox.Text)
    $DuplicateKeys = @{}
    $HostMappingCounts = @{}

    foreach ($Map in $Mappings) {
        $CountHost = ([string]$Map.Host).Trim().ToLowerInvariant()

        if (-not $HostMappingCounts.ContainsKey($CountHost)) {
            $HostMappingCounts[$CountHost] = 0
        }

        $HostMappingCounts[$CountHost]++


        $Key = "{0}|{1}|{2}|{3}" -f
            ([string]$Map.Host).Trim().ToLowerInvariant(),
            ([string]$Map.SourceIP).Trim().ToLowerInvariant(),
            ([string]$Map.Array).Trim().ToLowerInvariant(),
            ([string]$Map.TargetIP).Trim().ToLowerInvariant()

        if (-not $DuplicateKeys.ContainsKey($Key)) {
            $DuplicateKeys[$Key] = 0
        }

        $DuplicateKeys[$Key]++
    }

    $HostCache = @{}
    $Plan = @()
    $BlockingCount = 0

    Set-BusyState $true

    try {
        Write-ToolLog "ISCSI PREFLIGHT START - mappings=$($Mappings.Count)." "INFO"

        foreach ($Map in $Mappings) {
            $Map.TargetIQN = ""
            $Map.TCP3260 = ""
            $Map.PortalState = ""
            $Map.SessionState = ""
            $Map.Action = ""
            $Map.Result = ""

            $HostName = ([string]$Map.Host).Trim()
            $SourceIP = ([string]$Map.SourceIP).Trim()
            $ArrayIdentity = ([string]$Map.Array).Trim()
            $TargetIP = ([string]$Map.TargetIP).Trim()

            $Blocking = $false
            $Messages = New-Object System.Collections.Generic.List[string]

            if ([string]::IsNullOrWhiteSpace($HostName) -or
                [string]::IsNullOrWhiteSpace($SourceIP) -or
                [string]::IsNullOrWhiteSpace($ArrayIdentity) -or
                [string]::IsNullOrWhiteSpace($TargetIP)) {
                $Blocking = $true
                $Messages.Add("Host, Source IP, Array, and Target IP are required.")
            }

            $CountKey = $HostName.ToLowerInvariant()

            if ($HostName -and
                $HostMappingCounts.ContainsKey($CountKey) -and
                [int]$HostMappingCounts[$CountKey] -gt
                $script:WindowsMpioMaxPathsPerDevice) {
                $Blocking = $true
                $Messages.Add(
                    "Desired mapping count for this host exceeds the Windows 32-path maximum."
                )
            }

            if ($HostName -and
                @($HostsInScope | Where-Object { $_ -ieq $HostName }).Count -eq 0) {
                $Blocking = $true
                $Messages.Add("Host is not in the selected Windows host list.")
            }

            $Key = "{0}|{1}|{2}|{3}" -f
                $HostName.ToLowerInvariant(),
                $SourceIP.ToLowerInvariant(),
                $ArrayIdentity.ToLowerInvariant(),
                $TargetIP.ToLowerInvariant()

            if ($DuplicateKeys[$Key] -gt 1) {
                $Blocking = $true
                $Messages.Add("Duplicate desired mapping.")
            }

            $ArrayContext = $null

            if (-not $Blocking) {
                $ArrayContext = Get-IscsiArrayContext -ArrayIdentity $ArrayIdentity

                if (-not $ArrayContext) {
                    $Blocking = $true
                    $Messages.Add("Array is not present and connected in the Pure Registration array list.")
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($HostName) -and
                -not $HostCache.ContainsKey($HostName)) {
                try {
                    Write-ToolLog "ISCSI PREFLIGHT HOST START host=$HostName." "INFO"
                    $HostCache[$HostName] = Get-IscsiHostInventory -HostName $HostName
                }
                catch {
                    $HostCache[$HostName] = $null
                    $Blocking = $true
                    $Messages.Add("Unable to inventory host: $($_.Exception.Message)")
                }
            }

            $Inventory = $HostCache[$HostName]

            if ($Inventory) {
                if (-not $Inventory.ServiceRunning) {
                    $Blocking = $true
                    $Messages.Add("Microsoft iSCSI Initiator service is not running.")
                }

                if (-not $Inventory.MPIOInstalled) {
                    $Blocking = $true
                    $Messages.Add("Multipath-IO is not installed.")
                }

                if (-not $Inventory.PureDSM) {
                    $Blocking = $true
                    $Messages.Add("PURE / FlashArray is not registered with MSDSM.")
                }

                $SourceMatch = @(
                    $Inventory.SourceAddresses |
                        Where-Object { [string]$_.IPAddress -ieq $SourceIP }
                )

                if ($SourceMatch.Count -eq 0) {
                    $Blocking = $true
                    $Messages.Add("Selected source IP is not assigned to an enabled local NIC.")
                }
            }

            $TargetIQN = ""

            if ($ArrayContext -and
                -not [string]::IsNullOrWhiteSpace($TargetIP)) {
                try {
                    $TargetIQN = Resolve-PureIscsiTargetIqn `
                        -ArrayContext $ArrayContext `
                        -TargetIP $TargetIP

                    $Map.TargetIQN = $TargetIQN
                }
                catch {
                    $Blocking = $true
                    $Messages.Add($_.Exception.Message)
                }
            }

            $TcpPass = $false

            if (-not $Blocking -and $Inventory) {
                try {
                    $TcpPass = Test-IscsiSourceBoundTcp `
                        -HostName $HostName `
                        -SourceIP $SourceIP `
                        -TargetIP $TargetIP
                }
                catch {
                    $TcpPass = $false
                }
            }

            $Map.TCP3260 = if ($TcpPass) { "PASS" } else { "FAIL" }

            Write-ToolLog `
                "ISCSI TCP TEST host=$HostName source=$SourceIP target=$TargetIP port=3260 result=$($Map.TCP3260)." `
                "INFO"

            if (-not $TcpPass) {
                $Blocking = $true
                $Messages.Add("TCP/3260 failed from the intended source IP.")
            }

            $PortalState = "BLOCKED"
            $SessionState = "BLOCKED"

            if ($Inventory -and -not $Blocking) {
                $ExactPortals = @(
                    $Inventory.Portals |
                        Where-Object {
                            [string]$_.TargetPortalAddress -ieq $TargetIP -and
                            [int]$_.TargetPortalPortNumber -eq 3260 -and
                            [string]$_.InitiatorPortalAddress -ieq $SourceIP
                        }
                )

                if ($ExactPortals.Count -gt 1) {
                    $Blocking = $true
                    $Messages.Add("Duplicate exact target portal definitions were detected.")
                    $PortalState = "BLOCKED"
                }
                elseif ($ExactPortals.Count -eq 1) {
                    $PortalState = "MATCH"
                }
                else {
                    $PortalState = "CREATE"
                }

                $TargetConnected = @(
                    $Inventory.Sessions |
                        Where-Object {
                            [string]$_.TargetNodeAddress -ieq $TargetIQN -and
                            [bool]$_.IsConnected
                        }
                )

                $ExactConnections = @(
                    $Inventory.Connections |
                        Where-Object {
                            [string]$_.InitiatorAddress -ieq $SourceIP -and
                            [string]$_.TargetAddress -ieq $TargetIP -and
                            [int]$_.TargetPortNumber -eq 3260
                        }
                )

                if ($TargetConnected.Count -gt 0 -and
                    $ExactConnections.Count -gt 0) {
                    $PersistentMatch = $true

                    if ([bool]$IscsiPersistentCheckBox.IsChecked) {
                        $PersistentMatch = (
                            @(
                                $TargetConnected |
                                    Where-Object { [bool]$_.IsPersistent }
                            ).Count -gt 0
                        )
                    }

                    if ($PersistentMatch) {
                        $SessionState = "MATCH"
                    }
                    else {
                        $SessionState = "CONNECT"
                        $Messages.Add("Existing session is not persistent as requested; Apply will establish the requested persistent connection.")
                    }
                }
                else {
                    $SessionState = "CONNECT"
                }
            }

            $Map.PortalState = $PortalState
            $Map.SessionState = $SessionState

            $Action =
                if ($Blocking) {
                    "BLOCKED"
                }
                elseif ($PortalState -eq "CREATE" -and
                        $SessionState -eq "CONNECT") {
                    "CREATE PORTAL + CONNECT"
                }
                elseif ($PortalState -eq "CREATE") {
                    "CREATE PORTAL"
                }
                elseif ($SessionState -eq "CONNECT") {
                    "CONNECT"
                }
                else {
                    "MATCH"
                }

            $Map.Action = $Action

            $Map.Result =
                if ($Blocking) {
                    "BLOCKED - " + ($Messages -join " ")
                }
                elseif ($Messages.Count -gt 0) {
                    $Messages -join " "
                }
                else {
                    "Ready."
                }

            if ($Blocking) {
                $BlockingCount++
            }

            $Plan += [pscustomobject]@{
                Host         = $HostName
                SourceIP     = $SourceIP
                Array        = $ArrayIdentity
                Endpoint     = if ($ArrayContext) { $ArrayContext.Endpoint } else { "" }
                ArrayObject  = if ($ArrayContext) { $ArrayContext.Array } else { $null }
                TargetIP     = $TargetIP
                TargetPort   = 3260
                TargetIQN    = $TargetIQN
                PortalState  = $PortalState
                SessionState = $SessionState
                Action       = $Action
                Persistent   = [bool]$IscsiPersistentCheckBox.IsChecked
                Multipath    = [bool]$IscsiMultipathCheckBox.IsChecked
                MinimumPaths = $MinimumPaths
                Blocking     = $Blocking
                Message      = ($Messages -join " ")
            }

            Write-ToolLog `
                "ISCSI PLAN host=$HostName source=$SourceIP array=$ArrayIdentity target=$TargetIP portal=$PortalState session=$SessionState action=$Action blocking=$Blocking." `
                "INFO"

            $IscsiMappingGrid.Items.Refresh()
        }

        $script:IscsiConnectionPlan = @($Plan)
        $script:LastIscsiPreflightTime = Get-Date
        $script:LastIscsiValidationTime = Get-Date
        $script:IscsiInputSignature = Get-IscsiInputSignature

        if ($BlockingCount -eq 0) {
            $script:IscsiValidationReady = $true
            $script:IscsiValidationReason = "READY"
            $IscsiSummaryText.Text =
                "Validate / Dry Run complete: $($Plan.Count) mapping(s), 0 blocked. Existing correct configuration is MATCH."
            Set-GlobalStatus "iSCSI Validate / Dry Run complete - ready to Apply."
        }
        else {
            $script:IscsiValidationReady = $false
            $script:IscsiValidationReason = "BLOCKED"
            $IscsiSummaryText.Text =
                "Validate / Dry Run complete: $($Plan.Count) mapping(s), $BlockingCount blocked. Resolve blocked rows before Apply."
            Set-GlobalStatus "iSCSI Validate / Dry Run found $BlockingCount blocked mapping(s)."
        }

        Write-ToolLog `
            "ISCSI PLAN COMPLETE mappings=$($Plan.Count) blocked=$BlockingCount." `
            "INFO"
    }
    finally {
        Set-BusyState $false
        Update-IscsiControls
        Update-SessionStateBanner
    }
}

function Get-IscsiChangePreview {
    $Lines = New-Object System.Collections.Generic.List[string]
    $Lines.Add("iSCSI CONNECTION CHANGE PREVIEW")
    $Lines.Add("")

    if (@($script:IscsiConnectionPlan).Count -eq 0) {
        $Lines.Add("No iSCSI connection plan is currently available.")
        return ($Lines -join [Environment]::NewLine)
    }

    foreach ($HostGroup in @($script:IscsiConnectionPlan | Group-Object Host)) {
        $Lines.Add([string]$HostGroup.Name)

        foreach ($Plan in @($HostGroup.Group)) {
            $Lines.Add("  Array: $($Plan.Array)")
            $Lines.Add("  Source IP: $($Plan.SourceIP)")
            $Lines.Add("  Target: $($Plan.TargetIP):$($Plan.TargetPort)")
            $Lines.Add("  Target IQN: $($Plan.TargetIQN)")

            if ($Plan.PortalState -eq "CREATE") {
                $Lines.Add("  CREATE portal $($Plan.TargetIP) via local $($Plan.SourceIP)")
            }
            elseif ($Plan.PortalState -eq "MATCH") {
                $Lines.Add("  MATCH  portal $($Plan.TargetIP) via local $($Plan.SourceIP)")
            }
            else {
                $Lines.Add("  Portal: $($Plan.PortalState)")
            }

            if ($Plan.SessionState -eq "CONNECT") {
                $Lines.Add("  CONNECT target $($Plan.TargetIQN) using local source $($Plan.SourceIP)")
            }
            elseif ($Plan.SessionState -eq "MATCH") {
                $Lines.Add("  MATCH  active session to $($Plan.TargetIQN) using $($Plan.SourceIP)")
            }
            else {
                $Lines.Add("  Session: $($Plan.SessionState)")
            }

            $Lines.Add("  Persistent: $($Plan.Persistent)")
            $Lines.Add("  Multipath: $($Plan.Multipath)")

            if ($Plan.MinimumPaths -gt 0) {
                $Lines.Add("  Expected minimum paths: $($Plan.MinimumPaths)")
            }

            if ($Plan.Blocking) {
                $Lines.Add("  BLOCKED: $($Plan.Message)")
            }

            $Lines.Add("")
        }
    }

    $Lines.Add("Storage object changes:")
    $Lines.Add("  Pure volumes: 0")
    $Lines.Add("  LUN mappings: 0")
    $Lines.Add("  Pods: 0")
    $Lines.Add("  Protection Groups: 0")
    $Lines.Add("  Preferred-array changes: 0")
    $Lines.Add("  Disk initialization/formatting: 0")
    $Lines.Add("  CSV/Failover Cluster changes: 0")

    $Lines -join [Environment]::NewLine
}

function Show-IscsiChangePreview {
    [System.Windows.MessageBox]::Show(
        (Get-IscsiChangePreview),
        "iSCSI Connection Change Preview",
        "OK",
        "Information"
    ) | Out-Null
}

function Get-IscsiPostVerifyInventory {
    param([string]$HostName)

    Invoke-HostCommand -ComputerName $HostName -ScriptBlock {
        $Out = [ordered]@{
            Portals     = @()
            Sessions    = @()
            Connections = @()
            PureDisks   = @()
            DeviceMpio  = @()
            AluaDevices = @()
        }

        try {
            $Out.Portals = @(
                Get-IscsiTargetPortal -ErrorAction Stop |
                    Select-Object TargetPortalAddress,TargetPortalPortNumber,InitiatorPortalAddress
            )
        }
        catch {}

        try {
            $Out.Sessions = @(
                Get-IscsiSession -ErrorAction Stop |
                    Select-Object TargetNodeAddress,IsConnected,IsPersistent,NumberOfConnections
            )
        }
        catch {}

        try {
            $Out.Connections = @(
                Get-IscsiConnection -ErrorAction Stop |
                    Select-Object InitiatorAddress,TargetAddress,TargetPortNumber
            )
        }
        catch {}

        try {
            $Out.PureDisks = @(
                Get-Disk -ErrorAction Stop |
                    Where-Object { $_.FriendlyName -match "PURE|FlashArray" } |
                    Select-Object Number,FriendlyName,SerialNumber,OperationalStatus,HealthStatus,Size
            )
        }
        catch {}

        try {
            if (Get-Command Get-MSDSMLoadBalancePolicy -ErrorAction SilentlyContinue) {
                foreach ($Disk in @($Out.PureDisks)) {
                    try {
                        $PolicyObject = Get-MSDSMLoadBalancePolicy `
                            -Path ("\\?\PhysicalDrive{0}" -f $Disk.Number) `
                            -ErrorAction Stop

                        $Out.DeviceMpio += [pscustomobject]@{
                            DiskNumber = [int]$Disk.Number
                            Policy     = [string]$PolicyObject.LoadBalancePolicy
                        }
                    }
                    catch {}
                }
            }
        }
        catch {}

        try {
            foreach ($Lb in @(
                Get-CimInstance `
                    -Namespace root/wmi `
                    -ClassName DSM_QueryLBPolicy_V2 `
                    -ErrorAction Stop
            )) {
                try {
                    $Policy = $Lb.LoadBalancePolicy

                    if (-not $Policy) {
                        continue
                    }

                    $Out.AluaDevices += [pscustomobject]@{
                        InstanceName = [string]$Lb.InstanceName
                        PathCount    = [int]$Policy.DSMPathCount
                    }
                }
                catch {}
            }
        }
        catch {}

        [pscustomobject]$Out
    }
}

function Test-IscsiConnectionPostVerification {
    $Failures = New-Object System.Collections.Generic.List[string]
    $HostCache = @{}

    Write-ToolLog "ISCSI POST-VERIFY START." "INFO"

    foreach ($Plan in @(
        $script:IscsiConnectionPlan |
            Where-Object { -not $_.Blocking }
    )) {
        if (-not $HostCache.ContainsKey($Plan.Host)) {
            try {
                $HostCache[$Plan.Host] =
                    Get-IscsiPostVerifyInventory -HostName $Plan.Host
            }
            catch {
                $Failures.Add(
                    "$($Plan.Host): unable to collect post-verification inventory - $($_.Exception.Message)"
                )
                continue
            }
        }

        $Inventory = $HostCache[$Plan.Host]

        $PortalMatch = (
            @(
                $Inventory.Portals |
                    Where-Object {
                        [string]$_.TargetPortalAddress -ieq $Plan.TargetIP -and
                        [int]$_.TargetPortalPortNumber -eq 3260 -and
                        [string]$_.InitiatorPortalAddress -ieq $Plan.SourceIP
                    }
            ).Count -gt 0
        )

        if (-not $PortalMatch) {
            $Failures.Add(
                "$($Plan.Host): portal $($Plan.TargetIP) via $($Plan.SourceIP) was not verified."
            )
        }
        else {
            Write-ToolLog `
                "PORTAL VERIFY PASS host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP)." `
                "INFO"
        }

        $SessionMatch = (
            @(
                $Inventory.Sessions |
                    Where-Object {
                        [string]$_.TargetNodeAddress -ieq $Plan.TargetIQN -and
                        [bool]$_.IsConnected
                    }
            ).Count -gt 0
        )

        $ConnectionMatch = (
            @(
                $Inventory.Connections |
                    Where-Object {
                        [string]$_.InitiatorAddress -ieq $Plan.SourceIP -and
                        [string]$_.TargetAddress -ieq $Plan.TargetIP -and
                        [int]$_.TargetPortNumber -eq 3260
                    }
            ).Count -gt 0
        )

        if (-not ($SessionMatch -and $ConnectionMatch)) {
            $Failures.Add(
                "$($Plan.Host): active session/source/target tuple was not verified for $($Plan.SourceIP) -> $($Plan.TargetIP)."
            )
        }
        else {
            Write-ToolLog `
                "SESSION VERIFY PASS host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP) iqn=$($Plan.TargetIQN)." `
                "INFO"
        }

        if ($Plan.Persistent) {
            $PersistentMatch = (
                @(
                    $Inventory.Sessions |
                        Where-Object {
                            [string]$_.TargetNodeAddress -ieq $Plan.TargetIQN -and
                            [bool]$_.IsConnected -and
                            [bool]$_.IsPersistent
                        }
                ).Count -gt 0
            )

            if (-not $PersistentMatch) {
                $Failures.Add(
                    "$($Plan.Host): target $($Plan.TargetIQN) is connected but persistence was not verified."
                )
            }
        }

        if (@($Inventory.PureDisks).Count -eq 0) {
            Write-ToolLog `
                "PURE DEVICE VERIFY INFO host=$($Plan.Host): no Pure disks visible. LUN presentation may not yet exist; this tool does not create LUN mappings." `
                "INFO"
        }
    }

    foreach ($HostName in @($HostCache.Keys | Sort-Object)) {
        $Inventory = $HostCache[$HostName]
        $Disks = @($Inventory.PureDisks)
        $Policies = @($Inventory.DeviceMpio)
        $Alua = @($Inventory.AluaDevices)

        $CanCorrelate = (
            $Disks.Count -gt 0 -and
            $Policies.Count -gt 0 -and
            $Alua.Count -eq $Disks.Count
        )

        foreach ($Policy in $Policies) {
            $PathCount = 0

            if ($CanCorrelate) {
                $DiskIndex = -1

                for ($i = 0; $i -lt $Disks.Count; $i++) {
                    if ([int]$Disks[$i].Number -eq
                        [int]$Policy.DiskNumber) {
                        $DiskIndex = $i
                        break
                    }
                }

                if ($DiskIndex -ge 0 -and
                    $DiskIndex -lt $Alua.Count) {
                    $PathCount = [int]$Alua[$DiskIndex].PathCount
                }
            }

            $Expectation =
                Get-PureRecommendedMpioExpectation -PathCount $PathCount

            $PolicyText =
                ([string]$Policy.Policy).Trim().ToUpperInvariant()

            $IsRR = (
                $PolicyText -eq "RR" -or
                $PolicyText -match "ROUND\s*ROBIN"
            )

            $IsLQD = (
                $PolicyText -eq "LQD" -or
                $PolicyText -match "LEAST\s*QUEUE"
            )

            $PathText =
                if ($PathCount -gt 0) {
                    [string]$PathCount
                }
                else {
                    "Unknown"
                }

            $Line =
                "$HostName disk=$($Policy.DiskNumber) policy=$($Policy.Policy) paths=$PathText expected=$($Expectation.Expected)"

            Write-ToolLog "MPIO VERIFY $Line." "INFO"

            if ($Expectation.HardFail) {
                $Failures.Add(
                    "$HostName disk $($Policy.DiskNumber): $PathCount paths exceeds the Windows 32-path MPIO limit."
                )
            }
            elseif ($PathCount -gt 10 -and -not $IsLQD) {
                $Failures.Add(
                    "$HostName disk $($Policy.DiskNumber): $PathCount paths observed; LQD is expected for 11-32 Pure paths. Policy was not changed."
                )
            }
            elseif ($PathCount -gt 0 -and -not ($IsRR -or $IsLQD)) {
                $Failures.Add(
                    "$HostName disk $($Policy.DiskNumber): policy '$($Policy.Policy)' is not RR or LQD for $PathCount paths. Policy was not changed."
                )
            }
        }

        $HostMinimums = @(
            $script:IscsiConnectionPlan |
                Where-Object {
                    $_.Host -ieq $HostName -and
                    $_.MinimumPaths -gt 0
                } |
                Select-Object -ExpandProperty MinimumPaths -Unique
        )

        if ($HostMinimums.Count -gt 0 -and
            $Alua.Count -gt 0) {
            $RequiredMinimum =
                ($HostMinimums | Measure-Object -Maximum).Maximum

            foreach ($Device in $Alua) {
                if ([int]$Device.PathCount -lt
                    [int]$RequiredMinimum) {
                    $Failures.Add(
                        "${HostName}: observed $($Device.PathCount) MPIO paths, below configured minimum $RequiredMinimum."
                    )
                }
            }
        }
    }

    if ($Failures.Count -eq 0) {
        $script:LastIscsiApplyVerificationTime = Get-Date
        $script:IscsiValidationReason = "VERIFIED"

        $IscsiSummaryText.Text =
            "iSCSI Apply complete - VERIFIED. Portals, active sessions, intended source/target addressing, and available Pure/MPIO runtime data were checked."

        Set-GlobalStatus "iSCSI Apply complete - verified."
        Write-ToolLog "ISCSI POST-VERIFY COMPLETE result=PASS." "INFO"
        Update-SessionStateBanner
        return $true
    }

    $script:LastIscsiApplyVerificationTime = $null
    $script:IscsiValidationReason = "VERIFY FAILED"

    $IscsiSummaryText.Text =
        "iSCSI Apply completed, but post-verification requires review."

    $Message = (
        "iSCSI post-verification requires review:" +
        [Environment]::NewLine +
        [Environment]::NewLine +
        ($Failures -join [Environment]::NewLine) +
        [Environment]::NewLine +
        [Environment]::NewLine +
        "No disks were initialized or formatted, and no MPIO policy was changed."
    )

    [System.Windows.MessageBox]::Show(
        $Message,
        "iSCSI Post-Verification",
        "OK",
        "Warning"
    ) | Out-Null

    Write-ToolLog `
        "ISCSI POST-VERIFY COMPLETE result=FAILED issues=$($Failures -join '; ')." `
        "WARN"

    Update-SessionStateBanner
    $false
}

function Apply-IscsiConnections {
    if (-not $script:IscsiValidationReady) {
        [System.Windows.MessageBox]::Show(
            "Run iSCSI Validate / Dry Run and resolve all BLOCKED mappings first.",
            "Validation Required",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    if ((Get-IscsiInputSignature) -ne
        $script:IscsiInputSignature) {
        Invalidate-IscsiValidationState `
            -Reason "iSCSI inputs changed after validation"

        [System.Windows.MessageBox]::Show(
            "The iSCSI inputs changed after validation. Run Validate / Dry Run again.",
            "Plan Is Stale",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    foreach ($Plan in @($script:IscsiConnectionPlan)) {
        if ($Plan.Blocking) {
            [System.Windows.MessageBox]::Show(
                "The plan still contains BLOCKED rows. Run Validate / Dry Run again.",
                "Blocked Plan",
                "OK",
                "Warning"
            ) | Out-Null
            return
        }

        $ArrayContext =
            Get-IscsiArrayContext -ArrayIdentity $Plan.Array

        if (-not $ArrayContext) {
            Invalidate-IscsiValidationState `
                -Reason "Array disconnected before iSCSI Apply"

            [System.Windows.MessageBox]::Show(
                "Array '$($Plan.Array)' is no longer connected. Reconnect it and run Validate / Dry Run again.",
                "Array Connection Changed",
                "OK",
                "Warning"
            ) | Out-Null
            return
        }
    }

    $Preview = Get-IscsiChangePreview

    $ConfirmText = (
        $Preview +
        [Environment]::NewLine +
        [Environment]::NewLine +
        "Apply this iSCSI connection plan?" +
        [Environment]::NewLine +
        [Environment]::NewLine +
        "This may create Windows iSCSI target portals and persistent/multipath sessions." +
        [Environment]::NewLine +
        "It will NOT create or map Pure volumes, initialize or format disks, change MPIO policy, modify preferred-array settings, create CSVs, or modify Failover Cluster configuration."
    )

    $Confirmation = [System.Windows.MessageBox]::Show(
        $ConfirmText,
        "Apply iSCSI Connections",
        "YesNo",
        "Warning"
    )

    Write-ToolLog `
        "ISCSI APPLY confirmation returned: $Confirmation." `
        "INFO"

    if ($Confirmation -ne "Yes") {
        Set-GlobalStatus "iSCSI Apply cancelled."
        return
    }

    Set-BusyState $true
    $Failure = $null

    try {
        foreach ($Plan in @($script:IscsiConnectionPlan)) {
            if ($Plan.PortalState -eq "CREATE") {
                Write-ToolLog `
                    "PORTAL WRITE START host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP):3260." `
                    "CHANGE"

                Invoke-HostCommand `
                    -ComputerName $Plan.Host `
                    -ArgumentList @(
                        $Plan.TargetIP,
                        $Plan.SourceIP
                    ) `
                    -ScriptBlock {
                        param($TargetAddress,$InitiatorAddress)

                        New-IscsiTargetPortal `
                            -TargetPortalAddress $TargetAddress `
                            -TargetPortalPortNumber 3260 `
                            -InitiatorPortalAddress $InitiatorAddress `
                            -ErrorAction Stop |
                            Out-Null
                    }

                Write-ToolLog `
                    "PORTAL WRITE SUCCESS host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP):3260." `
                    "CHANGE"
            }
            else {
                Write-ToolLog `
                    "PORTAL MATCH host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP):3260." `
                    "INFO"
            }

            if ($Plan.SessionState -eq "CONNECT") {
                Write-ToolLog `
                    "SESSION CONNECT START host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP) iqn=$($Plan.TargetIQN) persistent=$($Plan.Persistent) multipath=$($Plan.Multipath)." `
                    "CHANGE"

                Invoke-HostCommand `
                    -ComputerName $Plan.Host `
                    -ArgumentList @(
                        $Plan.TargetIQN,
                        $Plan.TargetIP,
                        $Plan.SourceIP,
                        [bool]$Plan.Persistent,
                        [bool]$Plan.Multipath
                    ) `
                    -ScriptBlock {
                        param(
                            $NodeAddress,
                            $TargetAddress,
                            $InitiatorAddress,
                            $Persistent,
                            $Multipath
                        )

                        $Target = $null

                        for ($Attempt = 0;
                             $Attempt -lt 5;
                             $Attempt++) {
                            $Target =
                                Get-IscsiTarget -ErrorAction SilentlyContinue |
                                    Where-Object {
                                        [string]$_.NodeAddress -ieq
                                        $NodeAddress
                                    } |
                                    Select-Object -First 1

                            if ($Target) {
                                break
                            }

                            Start-Sleep -Seconds 1
                        }

                        if (-not $Target) {
                            throw "Target IQN '$NodeAddress' was not discovered after portal creation."
                        }

                        Connect-IscsiTarget `
                            -NodeAddress $NodeAddress `
                            -TargetPortalAddress $TargetAddress `
                            -TargetPortalPortNumber 3260 `
                            -InitiatorPortalAddress $InitiatorAddress `
                            -IsPersistent ([bool]$Persistent) `
                            -IsMultipathEnabled ([bool]$Multipath) `
                            -ErrorAction Stop |
                            Out-Null
                    }

                Write-ToolLog `
                    "SESSION CONNECT SUCCESS host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP) iqn=$($Plan.TargetIQN)." `
                    "CHANGE"
            }
            else {
                Write-ToolLog `
                    "SESSION MATCH host=$($Plan.Host) source=$($Plan.SourceIP) target=$($Plan.TargetIP) iqn=$($Plan.TargetIQN)." `
                    "INFO"
            }
        }
    }
    catch {
        $Failure = $_.Exception.Message
        Write-ToolLog "ISCSI APPLY FAILED: $Failure" "ERROR"
    }
    finally {
        $script:IscsiValidationReady = $false
        Set-BusyState $false
    }

    if ($Failure) {
        $script:IscsiValidationReason = "APPLY FAILED"

        $FailureMessage = (
            "iSCSI Apply stopped after an error:" +
            [Environment]::NewLine +
            [Environment]::NewLine +
            $Failure +
            [Environment]::NewLine +
            [Environment]::NewLine +
            "No further connection changes were attempted. Existing successful portal/session writes were not removed automatically. Review the log, verify Windows iSCSI state, then run Validate / Dry Run again."
        )

        [System.Windows.MessageBox]::Show(
            $FailureMessage,
            "iSCSI Apply Failed",
            "OK",
            "Error"
        ) | Out-Null

        Set-GlobalStatus "iSCSI Apply failed and stopped."
        Update-SessionStateBanner
        return
    }

    Write-ToolLog `
        "ISCSI APPLY COMPLETE planned=$(@($script:IscsiConnectionPlan).Count). Starting post-verification." `
        "INFO"

    Test-IscsiConnectionPostVerification | Out-Null
}

function Export-IscsiConnectionResults {
    if (@($script:IscsiConnectionResults).Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "There are no iSCSI mappings to export.",
            "No iSCSI Results",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    $Dialog = New-Object Microsoft.Win32.SaveFileDialog
    $Dialog.Filter =
        "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $Dialog.FileName =
        "iSCSI-Connection-Plan-{0}.csv" -f
        (Get-Date -Format "yyyyMMdd-HHmmss")
    $Dialog.DefaultExt = ".csv"

    if ($Dialog.ShowDialog()) {
        @($script:IscsiConnectionResults) |
            Export-Csv `
                -Path $Dialog.FileName `
                -NoTypeInformation `
                -Encoding UTF8

        Set-GlobalStatus `
            "Exported iSCSI connection results to $($Dialog.FileName)"
    }
}

function Update-ConflictReviewControls {
    if (-not $ReviewConflictButton) {
        return
    }

    try {
        $ReviewConflictButton.IsEnabled = $false

        if (-not $PureResultsGrid) {
            return
        }

        $Selected = $PureResultsGrid.SelectedItem

        if (-not $Selected) {
            $ReviewConflictButton.ToolTip =
                'Select a blocked conflict row to review or resolve.'
            return
        }

        $State =
            ([string]$Selected.State).Trim()

        $Result =
            ([string]$Selected.Result).Trim()

        $ReviewableStates = @(
            'HOST EXISTS - IQN MISSING',
            'NAME CONFLICT - DIFFERENT IQN',
            'IQN CONFLICT',
            'REVIEW',
            'BLOCKED'
        )

        $IsReviewable =
            (
                $ReviewableStates -contains $State -or
                $Result -match '^(BLOCKED|REVIEW)\b'
            )

        $ReviewConflictButton.IsEnabled =
            [bool]$IsReviewable

        if ($IsReviewable) {
            $ReviewConflictButton.ToolTip =
                "Review selected conflict: $State"
        }
        else {
            $ReviewConflictButton.ToolTip =
                "Selected row does not require conflict review: $State"
        }

        if ($PureSummaryText) {
            $ExistingText =
                [string]$PureSummaryText.Text

            $ExistingText =
                [regex]::Replace(
                    $ExistingText,
                    '\s*\|\s*Selected=.*$',
                    ''
                )

            $PureSummaryText.Text =
                "$ExistingText | Selected=$State | Review=$IsReviewable"
        }
    }
    catch {
        $ReviewConflictButton.IsEnabled = $false

        if ($ReviewConflictButton) {
            $ReviewConflictButton.ToolTip =
                "Conflict review state evaluation failed: $($_.Exception.Message)"
        }

        if (Get-Command Write-ToolLog -ErrorAction SilentlyContinue) {
            Write-ToolLog `
                "Update-ConflictReviewControls failed: $($_.Exception.Message)" `
                "ERROR"
        }
    }
}

function Get-ConnectedPureArrayContexts {
    $Contexts = @()

    foreach ($Entry in @($script:PureArrayEntries)) {
        if (-not $Entry) {
            continue
        }

        if (([string]$Entry.Status).Trim() -ne "Connected") {
            continue
        }

        $Endpoint = ""

        foreach ($PropertyName in @(
            "Endpoint",
            "ArrayEndpoint",
            "Address",
            "Fqdn"
        )) {
            if (
                $Entry.PSObject.Properties.Name -contains $PropertyName -and
                -not [string]::IsNullOrWhiteSpace([string]$Entry.$PropertyName)
            ) {
                $Endpoint = [string]$Entry.$PropertyName
                break
            }
        }

        $ApiObject = $null

        foreach ($PropertyName in @(
            "Array",
            "Connection",
            "Session",
            "Api",
            "Client"
        )) {
            if (
                $Entry.PSObject.Properties.Name -contains $PropertyName -and
                $null -ne $Entry.$PropertyName
            ) {
                $ApiObject = $Entry.$PropertyName
                break
            }
        }

        if (
            $null -eq $ApiObject -and
            $script:PureArrays
        ) {
            if (
                -not [string]::IsNullOrWhiteSpace($Endpoint) -and
                $script:PureArrays.ContainsKey($Endpoint)
            ) {
                $ApiObject = $script:PureArrays[$Endpoint]
            }
            elseif (
                $Entry.PSObject.Properties.Name -contains "ArrayName" -and
                $script:PureArrays.ContainsKey([string]$Entry.ArrayName)
            ) {
                $ApiObject = $script:PureArrays[[string]$Entry.ArrayName]
            }
        }

        if ($null -ne $ApiObject) {
            $Contexts += [pscustomobject]@{
                Endpoint = $Endpoint
                Array    = $ApiObject
            }
        }
    }

    return @($Contexts)
}

function Clear-ExistingHostGroupSelection {
    if (-not $HostGroupTextBox) {
        return
    }

    $HostGroupTextBox.IsDropDownOpen = $false
    $HostGroupTextBox.SelectedIndex = -1
    $HostGroupTextBox.SelectedItem = $null
    $HostGroupTextBox.Text = ""
}
function Refresh-ExistingHostGroups {
    param(
        [switch]$ShowMessages
    )

    if (-not $HostGroupTextBox) {
        return @()
    }

    $Contexts =
        @(Get-ConnectedPureArrayContexts)

    if ($Contexts.Count -eq 0) {
        $HostGroupTextBox.ItemsSource = $null
        $HostGroupTextBox.Text = ""

        if ($ShowMessages) {
            [System.Windows.MessageBox]::Show(
                "You must connect to at least one array before selecting an existing host group.",
                "Existing Host Group",
                "OK",
                "Information"
            ) | Out-Null
        }

        return @()
    }

    if (
        -not
        (Get-Command Get-Pfa2HostGroup -ErrorAction SilentlyContinue)
    ) {
        if ($ShowMessages) {
            [System.Windows.MessageBox]::Show(
                "Get-Pfa2HostGroup is not available. Verify PureStoragePowerShellSDK2 is installed and loaded.",
                "Existing Host Group",
                "OK",
                "Error"
            ) | Out-Null
        }

        return @()
    }

    $GroupSets = @()

    foreach ($Context in $Contexts) {
        try {
            $Groups =
                @(
                    Get-Pfa2HostGroup `
                        -Array $Context.Array `
                        -ErrorAction Stop
                )

            $Names =
                @(
                    $Groups |
                        ForEach-Object {
                            [string]$_.Name
                        } |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace($_)
                        } |
                        Sort-Object -Unique
                )

            $GroupSets += ,$Names
        }
        catch {
            Write-ToolLog `
                "Unable to retrieve host groups from $($Context.Endpoint): $($_.Exception.Message)" `
                "ERROR"

            if ($ShowMessages) {
                [System.Windows.MessageBox]::Show(
                    "Unable to retrieve host groups from $($Context.Endpoint).`n`n$($_.Exception.Message)",
                    "Existing Host Group",
                    "OK",
                    "Error"
                ) | Out-Null
            }

            return @()
        }
    }

    $CommonGroups = @()

    if ($GroupSets.Count -eq 1) {
        $CommonGroups = @($GroupSets[0])
    }
    else {
        $CommonGroups =
            @(
                $GroupSets[0] |
                    Where-Object {
                        $Name = $_

                        (
                            @(
                                $GroupSets |
                                    Where-Object {
                                        $_ -contains $Name
                                    }
                            ).Count
                        ) -eq $GroupSets.Count
                    } |
                    Sort-Object -Unique
            )
    }

    $CurrentText =
        [string]$HostGroupTextBox.Text

    $HostGroupTextBox.ItemsSource =
        $CommonGroups

    if (
        -not [string]::IsNullOrWhiteSpace($CurrentText) -and
        $CommonGroups -contains $CurrentText
    ) {
        $HostGroupTextBox.Text =
            $CurrentText
    }
    elseif ($CommonGroups.Count -gt 0) {
        $HostGroupTextBox.SelectedIndex =
            0
    }
    else {
        $HostGroupTextBox.Text =
            ""
    }

    Write-ToolLog `
        "Existing Host Group list refreshed. Connected arrays: $($Contexts.Count); common host groups: $($CommonGroups.Count)." `
        "INFO"

    if (
        $ShowMessages -and
        $CommonGroups.Count -eq 0
    ) {
        $Message =
            if ($Contexts.Count -eq 1) {
                "No host groups were found on the connected array."
            }
            else {
                "No host group exists on every connected array."
            }

        [System.Windows.MessageBox]::Show(
            $Message,
            "Existing Host Group",
            "OK",
            "Information"
        ) | Out-Null
    }

    return @($CommonGroups)
}
function Update-ValidationControls {
    if (-not $ValidatePureButton) {
        return
    }

    try {
        $IsBusyNow = $false

        if (
            (Get-Variable -Name IsBusy -Scope Script -ErrorAction SilentlyContinue) -and
            $script:IsBusy
        ) {
            $IsBusyNow = $true
        }

        $AuditComplete =
            [bool]$script:WindowsAuditComplete

        # Use the current audited result set as the authoritative
        # host/IQN source for the validation gate.
        $AuditedRows = @(
            $script:WindowsResults |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.Host)
                }
        )

        $AuditedHosts = @(
            $AuditedRows |
                ForEach-Object {
                    ([string]$_.Host).Trim()
                } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Sort-Object -Unique
        )

        $ValidIqnHosts = @(
            $AuditedRows |
                Where-Object {
                    ([string]$_.IQN).Trim() -match '^iqn\.'
                } |
                ForEach-Object {
                    ([string]$_.Host).Trim()
                } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Sort-Object -Unique
        )

        $HostCount =
            $AuditedHosts.Count

        $ValidIqnCount =
            $ValidIqnHosts.Count

        $AllHostsHaveIqns =
            (
                $AuditComplete -and
                $HostCount -gt 0 -and
                $ValidIqnCount -eq $HostCount
            )

        $ArrayEntries =
            @($script:PureArrayEntries)

        $ArrayCount =
            $ArrayEntries.Count

        $ConnectedCount =
            @(
                $ArrayEntries |
                    Where-Object {
                        ([string]$_.Status).Trim() -eq 'Connected'
                    }
            ).Count

        $AllArraysConnected =
            (
                $ArrayCount -gt 0 -and
                $ConnectedCount -eq $ArrayCount
            )

        $CanValidate =
            (
                -not $IsBusyNow -and
                $AuditComplete -and
                $AllHostsHaveIqns -and
                $AllArraysConnected
            )

        $ValidatePureButton.IsEnabled =
            $CanValidate

        if ($CanValidate) {
            $ValidatePureButton.ToolTip =
                'Run a new validation / Dry Run against the current audited hosts and connected arrays.'
        }
        else {
            $Reasons = @()

            if ($IsBusyNow) {
                $Reasons += 'Busy'
            }

            if (-not $AuditComplete) {
                $Reasons += 'Audit not current'
            }

            if (-not $AllHostsHaveIqns) {
                $Reasons += "IQNs $ValidIqnCount/$HostCount"
            }

            if ($ArrayCount -eq 0) {
                $Reasons += 'No arrays'
            }
            elseif (-not $AllArraysConnected) {
                $Reasons += "Arrays $ConnectedCount/$ArrayCount"
            }

            $ValidatePureButton.ToolTip =
                'Validate / Dry Run unavailable: ' +
                ($Reasons -join '; ')
        }

        if ($PureSummaryText) {
            $GateText =
                "Validate Gate: Audit=$AuditComplete | IQNs=$ValidIqnCount/$HostCount | Arrays=$ConnectedCount/$ArrayCount | Busy=$IsBusyNow"

            if ($CanValidate) {
                $PureSummaryText.Text =
                    "$GateText | READY"
            }
            else {
                $PureSummaryText.Text =
                    "$GateText | BLOCKED"
            }
        }
    }
    catch {
        $ValidatePureButton.IsEnabled = $false

        if ($ValidatePureButton) {
            $ValidatePureButton.ToolTip =
                "Validate / Dry Run unavailable: state evaluation failed - $($_.Exception.Message)"
        }

        if ($PureSummaryText) {
            $PureSummaryText.Text =
                "Validate Gate: ERROR - $($_.Exception.Message)"
        }

        if (Get-Command Write-ToolLog -ErrorAction SilentlyContinue) {
            Write-ToolLog `
                "Update-ValidationControls failed: $($_.Exception.Message)" `
                "ERROR"
        }
    }
}
function Get-HostList {
    param([string]$Text)

    @(
        $Text -split "[`r`n,; ]+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Set-GlobalStatus {
    param([string]$Text)
    $GlobalStatusText.Text = $Text
    $Window.Dispatcher.Invoke([action]{}, "Background")
}

function Set-BusyState {
param([bool]$Busy)

    $script:IsBusy = [bool]$Busy
foreach ($Button in @(
        $AuditButton,$ConfigureButton,$RebootButton,
        $WindowsCredentialButton,$WindowsCurrentUserButton,$ClearWindowsButton,
        $AddPureArrayButton,$AboutButton,$ResetSessionButton,$ExportAllButton,$ViewLogButton,$PreflightButton,$RetestArrayButton,$RemoveArrayButton,$ValidatePureButton,$ReviewConflictButton,$ApplyPureButton,
        $IscsiAddMappingButton,$IscsiRemoveMappingButton,$IscsiBuildPlanButton,$IscsiRefreshChoicesButton,$IscsiValidateButton,$IscsiPreviewButton,$IscsiApplyButton,$IscsiExportButton,
        $CheckPrereqButton,$InstallPrereqButton
    )) {
        if ($Button) {
            $Button.IsEnabled = -not $Busy
        }
    }

    if (-not $Busy) {

        if ($InstallPrereqButton) {
            $InstallPrereqButton.IsEnabled =
                @(
                    $script:PrereqResults |
                    Where-Object Status -eq "MISSING"
                ).Count -gt 0
        }

        $CurrentHosts = @(
            Get-HostList $HostTextBox.Text
        )

        $CurrentSignature =
            (
                $CurrentHosts |
                ForEach-Object {
                    $_.ToLowerInvariant()
                } |
                Sort-Object
            ) -join "|"

        $AuditIsCurrent =
            $script:WindowsAuditComplete -and
            -not [string]::IsNullOrWhiteSpace(
                $script:WindowsAuditHostSignature
            ) -and
            $script:WindowsAuditHostSignature -eq $CurrentSignature

        $HasConnectedArray =
            $script:PureConnected -and
            $script:PureArrays.Count -gt 0

        if ($ValidatePureButton) {
            $ValidatePureButton.IsEnabled =
                $AuditIsCurrent -and
                $HasConnectedArray
        }

        if ($ApplyPureButton) {
            $ApplyPureButton.IsEnabled =
                $script:PureValidationReady -and
                $AuditIsCurrent
        }

        if ($ReviewConflictButton) {
            if ($AuditIsCurrent) {
                Update-ConflictReviewButtonState
            }
            else {
                $ReviewConflictButton.IsEnabled = $false
            }
        }
    }

    if ($Busy) {
        $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    }
    else {
        $Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }

    $Window.Dispatcher.Invoke(
        [action]{},
        "Background"
    )

    Update-ValidationControls
    Update-IscsiControls
}

function Add-WindowsResult {
    param(
        [string]$HostName,
        [string]$IQN = "",
        [string]$MSiSCSI = "",
        [string]$MPIO = "",
        [string]$PureDSM = "",
        [string]$LBPolicy = "",
        [string]$MPIOTimers = "",
        [string]$PowerPlan = "",
        [string]$RebootRequired = "",
        [string]$Status = ""
    )

    $script:WindowsResults.Add([pscustomobject]@{
        Host = $HostName
        IQN = $IQN
        MSiSCSI = $MSiSCSI
        MPIO = $MPIO
        PureDSM = $PureDSM
        LBPolicy = $LBPolicy
        MPIOTimers = $MPIOTimers
        PowerPlan = $PowerPlan
        RebootRequired = $RebootRequired
        Status = $Status
    })
}

function Invoke-HostCommand {
    param(
        [string]$ComputerName,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $Params = @{
        ComputerName = $ComputerName
        ScriptBlock = $ScriptBlock
        ArgumentList = $ArgumentList
        ErrorAction = "Stop"
    }

    if ($script:WindowsCredential) {
        $Params.Credential = $script:WindowsCredential
    }

    Invoke-Command @Params
}

# ---------- Prerequisites ----------

function Test-ToolPrerequisites {
    $script:PrereqResults.Clear()

    $PSVersionOk = $PSVersionTable.PSVersion.Major -ge 5
    $script:PrereqResults.Add([pscustomobject]@{
        Component = "Windows PowerShell"
        Required = "5.1+"
        Detected = [string]$PSVersionTable.PSVersion
        Status = if ($PSVersionOk) { "PASS" } else { "FAILED" }
        Notes = if ($PSVersionOk) { "Supported." } else { "PowerShell 5.1 or later is required." }
    })

    $WpfOk = $true
    try {
        $null = [System.Windows.Window]
    }
    catch {
        $WpfOk = $false
    }
    $script:PrereqResults.Add([pscustomobject]@{
        Component = "Windows Presentation Foundation"
        Required = "Required"
        Detected = if ($WpfOk) { "Available" } else { "Unavailable" }
        Status = if ($WpfOk) { "PASS" } else { "FAILED" }
        Notes = "Required for the GUI."
    })

    $PSGet = Get-Module -ListAvailable -Name PowerShellGet |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $script:PrereqResults.Add([pscustomobject]@{
        Component = "PowerShellGet"
        Required = "Required"
        Detected = if ($PSGet) { [string]$PSGet.Version } else { "Not installed" }
        Status = if ($PSGet) { "PASS" } else { "FAILED" }
        Notes = "Required to install modules from PowerShell Gallery."
    })

    $Gallery = $null
    try {
        $Gallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
    }
    catch {}
    $script:PrereqResults.Add([pscustomobject]@{
        Component = "PowerShell Gallery"
        Required = "For SDK install"
        Detected = if ($Gallery) { $Gallery.SourceLocation } else { "Not registered" }
        Status = if ($Gallery) { "PASS" } else { "FAILED" }
        Notes = "The tool will not create or change repository configuration automatically."
    })

    $SDK = Get-Module -ListAvailable -Name PureStoragePowerShellSDK2 |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $script:PrereqResults.Add([pscustomobject]@{
        Component = "PureStoragePowerShellSDK2"
        Required = "Pure registration"
        Detected = if ($SDK) { [string]$SDK.Version } else { "Not installed" }
        Status = if ($SDK) { "PASS" } else { "MISSING" }
        Notes = if ($SDK) { "Pure FlashArray REST API 2.x PowerShell SDK." } else { "Install from PowerShell Gallery after approval." }
    })

    $RequiredCmdlets = @(
        "Connect-Pfa2Array",
        "Get-Pfa2Host",
        "New-Pfa2Host",
        "Update-Pfa2Host",
        "Get-Pfa2HostGroup",
        "New-Pfa2HostGroup"
    )

    $CmdletStatus = "PASS"
    $MissingCmdlets = @()

    if ($SDK) {
        try {
            Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
            foreach ($Cmdlet in $RequiredCmdlets) {
                if (-not (Get-Command $Cmdlet -ErrorAction SilentlyContinue)) {
                    $MissingCmdlets += $Cmdlet
                }
            }
            if ($MissingCmdlets.Count -gt 0) {
                $CmdletStatus = "FAILED"
            }
        }
        catch {
            $CmdletStatus = "FAILED"
            $MissingCmdlets = @("Module import failed: $($_.Exception.Message)")
        }
    }
    else {
        $CmdletStatus = "MISSING"
        $MissingCmdlets = @("SDK not installed")
    }

    $script:PrereqResults.Add([pscustomobject]@{
        Component = "Required Pure SDK cmdlets"
        Required = "Required"
        Detected = if ($MissingCmdlets.Count -eq 0) { "All detected" } else { $MissingCmdlets -join ", " }
        Status = $CmdletStatus
        Notes = "Pure registration remains disabled when this check fails."
    })

    $HardFailures = @($script:PrereqResults | Where-Object Status -eq "FAILED").Count
    $Missing = @($script:PrereqResults | Where-Object Status -eq "MISSING").Count

    $script:PrereqsHealthy = ($HardFailures -eq 0 -and $Missing -eq 0)

    if ($script:PrereqsHealthy) {
        $PrereqSummaryText.Text = "All required prerequisites are available. Pure registration is enabled."
        Write-ToolLog "Prerequisite check passed."
    }
    elseif ($HardFailures -gt 0) {
        $PrereqSummaryText.Text = "One or more prerequisites failed. Resolve FAILED items before Pure registration."
        Write-ToolLog "Prerequisite check found hard failures." "WARN"
    }
    else {
        $PrereqSummaryText.Text = "One or more installable prerequisites are missing. Review the list and use Install Missing if approved."
        Write-ToolLog "Prerequisite check found missing installable components." "WARN"
    }

    $InstallPrereqButton.IsEnabled = ($Missing -gt 0 -and $HardFailures -eq 0)
    $PrereqGrid.Items.Refresh()
}

function Install-MissingPrerequisites {
    $MissingSDK = -not (Get-Module -ListAvailable -Name PureStoragePowerShellSDK2)

    if (-not $MissingSDK) {
        Test-ToolPrerequisites
        return
    }

    $Message = @"
The following required component is missing:

PureStoragePowerShellSDK2

Source:
PowerShell Gallery (PSGallery)

Install command:
Install-Module -Name PureStoragePowerShellSDK2 -Scope CurrentUser

The module will be installed only for the current Windows user.

The tool will stop the Pure registration workflow if the install or module verification fails.

Install now?
"@

    $Confirm = [System.Windows.MessageBox]::Show(
        $Message,
        "Install Required Pure Storage SDK",
        "YesNo",
        "Warning"
    )

    if ($Confirm -ne "Yes") {
        Set-GlobalStatus "SDK installation cancelled. Pure registration remains unavailable."
        Write-ToolLog "User declined PureStoragePowerShellSDK2 installation." "WARN"
        return
    }

    Set-BusyState $true
    Set-GlobalStatus "Installing PureStoragePowerShellSDK2..."

    try {
        # Use TLS 1.2 for this PowerShell process when supported.
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
        catch {}

        Install-Module -Name PureStoragePowerShellSDK2 `
            -Scope CurrentUser `
            -Repository PSGallery `
            -Force `
            -AllowClobber `
            -ErrorAction Stop

        Import-Module PureStoragePowerShellSDK2 -Force -ErrorAction Stop

        $RequiredCmdlets = @(
            "Connect-Pfa2Array",
            "Get-Pfa2Host",
            "New-Pfa2Host",
            "Update-Pfa2Host",
            "Get-Pfa2HostGroup",
            "New-Pfa2HostGroup"
        )

        foreach ($Cmdlet in $RequiredCmdlets) {
            if (-not (Get-Command $Cmdlet -ErrorAction SilentlyContinue)) {
                throw "Required cmdlet '$Cmdlet' was not found after installation."
            }
        }

        Write-ToolLog "Installed and verified PureStoragePowerShellSDK2." "CHANGE"
        [System.Windows.MessageBox]::Show(
            "PureStoragePowerShellSDK2 installed and verified successfully.",
            "Installation Complete",
            "OK",
            "Information"
        ) | Out-Null

        Test-ToolPrerequisites
        Set-GlobalStatus "Prerequisite installation complete."
    }
    catch {
        $ErrorText = $_.Exception.Message
        Write-ToolLog "PureStoragePowerShellSDK2 install failed: $ErrorText" "ERROR"

        $script:PrereqsHealthy = $false
        $script:PureConnected = $false
        $script:PureValidationReady = $false
        $ApplyPureButton.IsEnabled = $false

        [System.Windows.MessageBox]::Show(
            "PureStoragePowerShellSDK2 installation or verification failed.`n`n$ErrorText`n`nPure registration has been stopped.",
            "Prerequisite Installation Failed",
            "OK",
            "Error"
        ) | Out-Null

        Set-GlobalStatus "SDK installation failed. Pure registration stopped."
        Test-ToolPrerequisites
    }
    finally {
        Set-BusyState $false

    }
}

# ---------- Windows audit/configuration ----------

$AuditScript = {
    $ErrorActionPreference = "Stop"

    $Result = [ordered]@{
        IQN = ""
        MSiSCSI = ""
        MPIO = ""
        PureDSM = ""
        LBPolicy = ""
        MPIOTimers = ""
        PowerPlan = ""
        RebootRequired = "No"
        Status = ""
    }

    $Svc = Get-Service -Name MSiSCSI -ErrorAction Stop
    $Result.MSiSCSI = "{0}/{1}" -f $Svc.StartType, $Svc.Status

    try {
        Import-Module iSCSI -ErrorAction Stop
        $IQN = Get-InitiatorPort |
            Where-Object { $_.NodeAddress -like "iqn.*" } |
            Select-Object -First 1 -ExpandProperty NodeAddress
        $Result.IQN = if ($IQN) { [string]$IQN } else { "Not initialized" }
    }
    catch {
        $Result.IQN = "Unavailable"
    }

    $Feature = Get-WindowsFeature -Name Multipath-IO -ErrorAction Stop
    if ($Feature.Installed) {
        $Result.MPIO = "Installed"
        try {
            Import-Module MPIO -ErrorAction Stop

            $Supported = @(Get-MSDSMSupportedHw -ErrorAction Stop)
            $Pure = $Supported | Where-Object {
                ([string]$_.VendorId).Trim() -eq "PURE" -and
                ([string]$_.ProductId).Trim() -eq "FlashArray"
            }
            $Result.PureDSM = if ($Pure) { "Configured" } else { "Missing" }

            try {
                $Result.LBPolicy = [string](Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction Stop)
            }
            catch {
                $Result.LBPolicy = "Unknown"
            }

            try {
                $Setting = Get-MPIOSetting -ErrorAction Stop

                $PathVerificationEnabled =
                    ([string]$Setting.PathVerificationState -match "Enabled|1|True")

                $CustomRecoveryEnabled =
                    ([string]$Setting.UseCustomPathRecoveryTime -match "Enabled|1|True") -or
                    ([string]$Setting.CustomPathRecovery -match "Enabled|1|True")

                $PathRecovery = $null
                foreach ($Name in @("CustomPathRecoveryTime","PathRecoveryInterval","NewPathRecoveryInterval")) {
                    if ($Setting.PSObject.Properties.Name -contains $Name) {
                        $PathRecovery = [int]$Setting.$Name
                        break
                    }
                }

                $PDORemove = $null
                foreach ($Name in @("PDORemovePeriod","PDORemovePeriodValue")) {
                    if ($Setting.PSObject.Properties.Name -contains $Name) {
                        $PDORemove = [int]$Setting.$Name
                        break
                    }
                }

                $DiskTimeout = $null
                foreach ($Name in @("DiskTimeoutValue","DiskTimeout","DiskTimeoutValueSeconds")) {
                    if ($Setting.PSObject.Properties.Name -contains $Name) {
                        $DiskTimeout = [int]$Setting.$Name
                        break
                    }
                }

                if ($PathVerificationEnabled -and
                    $CustomRecoveryEnabled -and
                    $PathRecovery -eq 20 -and
                    $PDORemove -eq 30 -and
                    $DiskTimeout -eq 60) {
                    $Result.MPIOTimers = "Pure baseline"
                }
                else {
                    $Result.MPIOTimers = "Review"
                }
            }
            catch {
                $Result.MPIOTimers = "Unknown"
            }
        }
        catch {
            $Result.PureDSM = "Unavailable"
            $Result.LBPolicy = "Unavailable"
            $Result.MPIOTimers = "Unavailable"
        }
    }
    else {
        $Result.MPIO = "Not installed"
        $Result.PureDSM = "N/A"
        $Result.LBPolicy = "N/A"
        $Result.MPIOTimers = "N/A"
    }

    try {
        $ActivePlan = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan |
            Where-Object IsActive |
            Select-Object -First 1
        $Result.PowerPlan = [string]$ActivePlan.ElementName
    }
    catch {
        $Result.PowerPlan = "Unknown"
    }

    $Issues = New-Object System.Collections.Generic.List[string]

    if ($Svc.StartType -ne "Automatic" -or $Svc.Status -ne "Running") {
        $Issues.Add("MSiSCSI")
    }
    if (-not $Feature.Installed) {
        $Issues.Add("MPIO")
    }
    elseif ($Result.PureDSM -ne "Configured") {
        $Issues.Add("PURE DSM")
    }
    if ($Feature.Installed -and $Result.LBPolicy -notmatch "RR|Round") {
        $Issues.Add("LB policy")
    }
    if ($Feature.Installed -and $Result.MPIOTimers -ne "Pure baseline") {
        $Issues.Add("MPIO timers")
    }
    if ($Result.PowerPlan -notmatch "High performance|High Performance") {
        $Issues.Add("Power plan")
    }

    if ($Issues.Count -eq 0) {
        $Result.Status = "PASS - Pure host baseline"
    }
    else {
        $Result.Status = "REVIEW: " + ($Issues -join ", ")
    }

    [pscustomobject]$Result
}

$ConfigureScript = {
    $ErrorActionPreference = "Stop"

    $Actions = New-Object System.Collections.Generic.List[string]
    $Warnings = New-Object System.Collections.Generic.List[string]
    $RebootRequired = $false

    $Svc = Get-Service -Name MSiSCSI -ErrorAction Stop
    if ($Svc.StartType -ne "Automatic") {
        Set-Service -Name MSiSCSI -StartupType Automatic -ErrorAction Stop
        $Actions.Add("MSiSCSI startup=Automatic")
    }
    if ($Svc.Status -ne "Running") {
        Start-Service -Name MSiSCSI -ErrorAction Stop
        $Actions.Add("MSiSCSI started")
    }

    Import-Module iSCSI -ErrorAction Stop
    $null = Get-InitiatorPort -ErrorAction Stop

    $Feature = Get-WindowsFeature -Name Multipath-IO -ErrorAction Stop
    if (-not $Feature.Installed) {
        $InstallResult = Install-WindowsFeature -Name Multipath-IO -ErrorAction Stop
        $Actions.Add("Multipath-IO installed")
        if ($InstallResult.RestartNeeded -and $InstallResult.RestartNeeded -ne "No") {
            $RebootRequired = $true
        }
    }

    try {
        Import-Module MPIO -ErrorAction Stop

        $Supported = @(Get-MSDSMSupportedHw -ErrorAction Stop)
        $Pure = $Supported | Where-Object {
            ([string]$_.VendorId).Trim() -eq "PURE" -and
            ([string]$_.ProductId).Trim() -eq "FlashArray"
        }

        if (-not $Pure) {
            New-MSDSMSupportedHw -VendorId "PURE" -ProductId "FlashArray" -ErrorAction Stop
            $Actions.Add("PURE FlashArray DSM registered")
            $RebootRequired = $true
        }

        $Policy = Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction SilentlyContinue
        if ([string]$Policy -notmatch "RR|Round") {
            Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR -ErrorAction Stop -WarningAction SilentlyContinue
            $Actions.Add("MPIO policy=RR")
        }

        Set-MPIOSetting ` -WarningAction SilentlyContinue
            -NewPathRecoveryInterval 20 `
            -CustomPathRecovery Enabled `
            -NewPDORemovePeriod 30 `
            -NewDiskTimeout 60 `
            -NewPathVerificationState Enabled `
            -ErrorAction Stop

        $Actions.Add("Pure MPIO timers applied")
        $RebootRequired = $true
    }
    catch {
        $Warnings.Add("MPIO post-install configuration could not complete: $($_.Exception.Message)")
        $Warnings.Add("Reboot, then run Configure Pure Best Practices again.")
        $RebootRequired = $true
    }

    try {
        $High = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan |
            Where-Object { $_.ElementName -match "^High performance$" } |
            Select-Object -First 1

        if ($High) {
            $Active = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan |
                Where-Object IsActive |
                Select-Object -First 1

            if ($Active.ElementName -notmatch "^High performance$") {
                $Guid = ([string]$High.InstanceID).
                    Replace("Microsoft:PowerPlan\{","").
                    Replace("}","")
                & powercfg.exe /setactive $Guid | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "powercfg.exe returned exit code $LASTEXITCODE"
                }
                $Actions.Add("Power plan=High Performance")
            }
        }
        else {
            $Warnings.Add("High Performance power plan not found.")
        }
    }
    catch {
        $Warnings.Add("Power plan could not be configured: $($_.Exception.Message)")
    }

    $SvcFinal = Get-Service -Name MSiSCSI
    $IQN = Get-InitiatorPort |
        Where-Object { $_.NodeAddress -like "iqn.*" } |
        Select-Object -First 1 -ExpandProperty NodeAddress

    $FeatureFinal = Get-WindowsFeature -Name Multipath-IO
    $PureDSM = "Unknown"
    $LB = "Unknown"

    if ($FeatureFinal.Installed) {
        try {
            Import-Module MPIO -ErrorAction Stop
            $SupportedFinal = @(Get-MSDSMSupportedHw -ErrorAction Stop)
            if ($SupportedFinal | Where-Object {
                ([string]$_.VendorId).Trim() -eq "PURE" -and
                ([string]$_.ProductId).Trim() -eq "FlashArray"
            }) {
                $PureDSM = "Configured"
            }
            else {
                $PureDSM = "Missing"
            }

            $LB = [string](Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction Stop)
        }
        catch {
            $PureDSM = "Pending reboot"
            $LB = "Pending reboot"
        }
    }

    try {
        $ActivePlan = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan |
            Where-Object IsActive |
            Select-Object -First 1
        $PowerPlan = [string]$ActivePlan.ElementName
    }
    catch {
        $PowerPlan = "Unknown"
    }

    $StatusParts = New-Object System.Collections.Generic.List[string]
    if ($Actions.Count -gt 0) {
        $StatusParts.Add("Changed: " + ($Actions -join "; "))
    }
    else {
        $StatusParts.Add("No host-level changes required")
    }
    if ($Warnings.Count -gt 0) {
        $StatusParts.Add("Warning: " + ($Warnings -join " "))
    }

    [pscustomobject]@{
        IQN = if ($IQN) { [string]$IQN } else { "Not initialized" }
        MSiSCSI = "{0}/{1}" -f $SvcFinal.StartType, $SvcFinal.Status
        MPIO = if ($FeatureFinal.Installed) { "Installed" } else { "Not installed" }
        PureDSM = $PureDSM
        LBPolicy = $LB
        MPIOTimers = if ($RebootRequired) { "Applied; reboot pending" } else { "Applied" }
        PowerPlan = $PowerPlan
        RebootRequired = if ($RebootRequired) { "Yes" } else { "No" }
        Status = ($StatusParts -join " | ")
    }
}

function Invoke-WindowsAuditCore {
    $Hosts = @(Get-HostList $HostTextBox.Text)

    if ($Hosts.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Enter at least one hostname.",
            "No Hosts",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    # Starting an audit invalidates any previous Pure validation.
    $script:WindowsAuditComplete = $false
    $script:WindowsAuditHostSignature = ""
    $script:PureValidationReady = $false

    $ValidatePureButton.IsEnabled = $false
    $ApplyPureButton.IsEnabled = $false
    $ReviewConflictButton.IsEnabled = $false

    $script:WindowsResults.Clear()

    Set-BusyState $true

    try {
        $Index = 0

        $AuditFailures =
            New-Object System.Collections.Generic.List[string]

        foreach ($HostName in $Hosts) {
            $Index++

            Set-GlobalStatus `
                "Auditing $HostName ($Index of $($Hosts.Count))..."

            try {
                $Result =
                    Invoke-HostCommand `
                        -ComputerName $HostName `
                        -ScriptBlock $AuditScript

                Add-WindowsResult `
                    -HostName $HostName `
                    -IQN ([string]$Result.IQN) `
                    -MSiSCSI ([string]$Result.MSiSCSI) `
                    -MPIO ([string]$Result.MPIO) `
                    -PureDSM ([string]$Result.PureDSM) `
                    -LBPolicy ([string]$Result.LBPolicy) `
                    -MPIOTimers ([string]$Result.MPIOTimers) `
                    -PowerPlan ([string]$Result.PowerPlan) `
                    -RebootRequired ([string]$Result.RebootRequired) `
                    -Status ([string]$Result.Status)

                if ([string]$Result.IQN -notlike "iqn.*") {
                    $AuditFailures.Add(
                        "$HostName did not return a valid Microsoft iSCSI IQN."
                    )
                }
            }
            catch {
                Add-WindowsResult `
                    -HostName $HostName `
                    -Status $_.Exception.Message

                $AuditFailures.Add(
                    "${HostName}: $($_.Exception.Message)"
                )

                Write-ToolLog `
                    "Windows audit failed for ${HostName}: $($_.Exception.Message)" `
                    "ERROR"
            }
        }

        # Independently verify that every requested host has exactly
        # one audited result with a valid IQN.
        foreach ($HostName in $Hosts) {

            $Rows = @(
                $script:WindowsResults |
                Where-Object {
                    $_.Host -ieq $HostName
                }
            )

            if ($Rows.Count -ne 1) {
                $AuditFailures.Add(
                    "$HostName does not have exactly one audit result."
                )

                continue
            }

            if ([string]$Rows[0].IQN -notlike "iqn.*") {
                $AuditFailures.Add(
                    "$HostName does not have a valid audited IQN."
                )
            }
        }

        $AuditFailures = @(
            $AuditFailures |
            Select-Object -Unique
        )

        if ($AuditFailures.Count -eq 0) {

            $script:WindowsAuditComplete = $true

            $script:WindowsAuditHostSignature =
                (
                    $Hosts |
                    ForEach-Object {
                        $_.ToLowerInvariant()
                    } |
                    Sort-Object
                ) -join "|"

            Set-GlobalStatus `
                "Windows Audit: PASS - $($Hosts.Count) of $($Hosts.Count) hosts verified."

            Write-ToolLog `
                "Windows audit prerequisite passed. $($Hosts.Count) hosts returned valid IQNs."
        }
        else {
            $script:WindowsAuditComplete = $false
            $script:WindowsAuditHostSignature = ""

            Set-GlobalStatus `
                "Windows Audit: FAILED - re-audit required before Pure validation."

            Write-ToolLog `
                "Windows audit prerequisite failed: $($AuditFailures -join '; ')" `
                "WARN"

            [System.Windows.MessageBox]::Show(
                "Windows Audit did not complete successfully for all hosts.`n`n$($AuditFailures -join "`n")`n`nValidate / Dry Run will remain disabled.",
                "Windows Audit Incomplete",
                "OK",
                "Warning"
            ) | Out-Null
        }
    }
    finally {
        Set-BusyState $false
    }
}

function Invoke-WindowsAudit {
    $script:LastWindowsAuditTime = $null

    Invoke-WindowsAuditCore

    if ($script:WindowsAuditComplete) {
        $script:LastWindowsAuditTime = Get-Date
    }

    Invalidate-PureValidationState `
        -Reason "Windows audit rerun"

    Update-SessionStateBanner

    Update-ValidationControls
}

function Get-WindowsHostIqns {
    $Hosts = @(Get-HostList $HostTextBox.Text)
    $Mappings = @()

    foreach ($HostName in $Hosts) {
        $Existing = $script:WindowsResults |
            Where-Object { $_.Host -ieq $HostName -and $_.IQN -like "iqn.*" } |
            Select-Object -First 1

        if ($Existing) {
            $Mappings += [pscustomobject]@{
                Host = $HostName
                IQN = [string]$Existing.IQN
            }
            continue
        }

        try {
            $IQN = Invoke-HostCommand -ComputerName $HostName -ScriptBlock {
                $Svc = Get-Service MSiSCSI -ErrorAction Stop
                if ($Svc.Status -ne "Running") {
                    throw "MSiSCSI is not running."
                }
                Import-Module iSCSI -ErrorAction Stop
                Get-InitiatorPort |
                    Where-Object { $_.NodeAddress -like "iqn.*" } |
                    Select-Object -First 1 -ExpandProperty NodeAddress
            }

            if (-not $IQN) {
                throw "No Microsoft iSCSI IQN was returned."
            }

            $Mappings += [pscustomobject]@{
                Host = $HostName
                IQN = [string]$IQN
            }
        }
        catch {
            throw "Unable to obtain IQN from $HostName. $($_.Exception.Message)"
        }
    }

    $Mappings
}

# ---------- Pure helpers ----------

function Get-SavedArrayEntropy {
    [byte[]]$Entropy =
        [System.Text.Encoding]::UTF8.GetBytes(
            "iSCSI-Host-Tool|SavedArrays|v1"
        )

    return $Entropy
}

function Protect-SavedArrayData {
    param(
        [Parameter(Mandatory)]
        [string]$PlainText
    )

    Add-Type -AssemblyName System.Security

    [byte[]]$Entropy = Get-SavedArrayEntropy
    [byte[]]$PlainBytes =
        [System.Text.Encoding]::UTF8.GetBytes($PlainText)

    # First bind the data to the current Windows user.
    [byte[]]$UserProtected =
        [System.Security.Cryptography.ProtectedData]::Protect(
            $PlainBytes,
            $Entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )

    # Then bind that protected blob to the current computer.
    [byte[]]$MachineAndUserProtected =
        [System.Security.Cryptography.ProtectedData]::Protect(
            $UserProtected,
            $Entropy,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )

    return [Convert]::ToBase64String(
        $MachineAndUserProtected
    )
}

function Unprotect-SavedArrayData {
    param(
        [Parameter(Mandatory)]
        [string]$ProtectedText
    )

    Add-Type -AssemblyName System.Security

    [byte[]]$Entropy = Get-SavedArrayEntropy

    [byte[]]$MachineAndUserProtected =
        [Convert]::FromBase64String(
            $ProtectedText.Trim()
        )

    # Must be the same computer.
    [byte[]]$UserProtected =
        [System.Security.Cryptography.ProtectedData]::Unprotect(
            $MachineAndUserProtected,
            $Entropy,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )

    # Must also be the same Windows user.
    [byte[]]$PlainBytes =
        [System.Security.Cryptography.ProtectedData]::Unprotect(
            $UserProtected,
            $Entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )

    return [System.Text.Encoding]::UTF8.GetString(
        $PlainBytes
    )
}
function Save-SavedArrays {
    try {
        if (-not (Test-Path $script:SavedArrayRoot)) {
            New-Item `
                -ItemType Directory `
                -Path $script:SavedArrayRoot `
                -Force |
                Out-Null
        }

        $Saved = @(
            $script:PureArrayEntries |
                Where-Object {
                    $_.Status -eq "Connected" -or
                    $_.Status -eq "Saved - Not Connected" -or
                    $_.Status -eq "Authentication Failed"
                } |
                ForEach-Object {
                    [pscustomobject]@{
                        Endpoint  = [string]$_.Endpoint
                        ArrayName = [string]$_.ArrayName
                    }
                } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace(
                        $_.Endpoint
                    )
                } |
                Sort-Object Endpoint -Unique
        )

        $Document = [pscustomobject]@{
            Version = 1
            Arrays  = $Saved
        }

        $Json =
            $Document |
            ConvertTo-Json -Depth 4

        $Encrypted =
            Protect-SavedArrayData `
                -PlainText $Json

        Set-Content `
            -Path $script:SavedArrayPath `
            -Value $Encrypted `
            -Encoding ASCII

        # Mark rows as persisted without changing the operational Status
        # property used elsewhere in the tool.
        foreach ($Entry in $script:PureArrayEntries) {
            $IsSaved =
                @(
                    $Saved |
                        Where-Object {
                            $_.Endpoint -ieq $Entry.Endpoint
                        }
                ).Count -gt 0

            if (
                $Entry.PSObject.Properties.Name -contains
                "SavedState"
            ) {
                $Entry.SavedState =
                    if ($IsSaved) { "Yes" } else { "No" }
            }
            else {
                $Entry |
                    Add-Member `
                        -NotePropertyName SavedState `
                        -NotePropertyValue $(if ($IsSaved) { "Yes" } else { "No" }) `
                        -Force
            }
        }

        if ($FlashArrayGrid) {
            $FlashArrayGrid.Items.Refresh()
        }

        # Connect Saved is useful only when at least one saved entry
        # is currently disconnected.
        if ($ConnectSavedArraysButton) {
            $ConnectSavedArraysButton.IsEnabled =
                @(
                    $script:PureArrayEntries |
                        Where-Object {
                            $_.SavedState -eq "Yes" -and
                            $_.Status -ne "Connected"
                        }
                ).Count -gt 0
        }

        Write-ToolLog `
            "Saved $($Saved.Count) encrypted array definition(s) to $script:SavedArrayPath."
    }
    catch {
        Write-ToolLog `
            "Unable to save encrypted array definitions: $($_.Exception.Message)" `
            "WARN"

        [System.Windows.MessageBox]::Show(
            "The connected array list could not be securely saved.`n`n$($_.Exception.Message)",
            "Saved Array Security",
            "OK",
            "Warning"
        ) | Out-Null
    }
}

function Load-SavedArrays {

    if ($ConnectSavedArraysButton) {
        $ConnectSavedArraysButton.IsEnabled = $false
    }

    $Document = $null
    $MigratedLegacyFile = $false

    try {
        if (Test-Path $script:SavedArrayPath) {

            $Encrypted =
                Get-Content `
                    -Path $script:SavedArrayPath `
                    -Raw `
                    -ErrorAction Stop

            $Json =
                Unprotect-SavedArrayData `
                    -ProtectedText $Encrypted

            $Document =
                $Json |
                ConvertFrom-Json `
                    -ErrorAction Stop
        }
        elseif (
            $script:LegacySavedArrayPath -and
            (Test-Path $script:LegacySavedArrayPath)
        ) {
            # One-time migration from the older plaintext JSON format.
            $Document =
                Get-Content `
                    -Path $script:LegacySavedArrayPath `
                    -Raw `
                    -ErrorAction Stop |
                ConvertFrom-Json `
                    -ErrorAction Stop

            $MigratedLegacyFile = $true
        }
        else {
            return
        }

        $SavedArrays = @(
            $Document.Arrays |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$_.Endpoint
                    )
                }
        )

        foreach ($Saved in $SavedArrays) {

            $Endpoint = [string]$Saved.Endpoint

            $Existing = @(
                $script:PureArrayEntries |
                    Where-Object {
                        $_.Endpoint -ieq $Endpoint
                    }
            )

            if ($Existing.Count -gt 0) {
                continue
            }

            $script:PureArrayEntries.Add(
                [pscustomobject]@{
                    Endpoint   = $Endpoint
                    Username   = ""
                    ArrayName  = [string]$Saved.ArrayName
                    Status     = "Saved - Not Connected"
                    SavedState = "Yes"
                    Credential = $null
                    Connection = $null
                }
            )
        }

        $SavedCount = @(
            $script:PureArrayEntries |
                Where-Object {
                    $_.SavedState -eq "Yes"
                }
        ).Count

        if ($ConnectSavedArraysButton) {
            $ConnectSavedArraysButton.IsEnabled =
                $SavedCount -gt 0
        }

        if ($SavedCount -gt 0) {
            $PureSummaryText.Text =
                "$SavedCount securely saved array(s) loaded. Click Connect Saved to authenticate."

            Set-GlobalStatus `
                "$SavedCount securely saved array(s) loaded."
        }

        if ($FlashArrayGrid) {
            $FlashArrayGrid.Items.Refresh()
        }

        if ($MigratedLegacyFile) {
            # Rewrite immediately using DPAPI.
            Save-SavedArrays

            if (Test-Path $script:SavedArrayPath) {
                Remove-Item `
                    -Path $script:LegacySavedArrayPath `
                    -Force `
                    -ErrorAction Stop

                Write-ToolLog `
                    "Migrated plaintext saved-array configuration to DPAPI protection and removed the legacy JSON file."
            }
        }
    }
    catch {
        if ($ConnectSavedArraysButton) {
            $ConnectSavedArraysButton.IsEnabled = $false
        }

        Write-ToolLog `
            "Unable to load protected saved arrays: $($_.Exception.Message)" `
            "WARN"

        [System.Windows.MessageBox]::Show(
            "The saved array list could not be decrypted.`n`nThis can occur if the saved file was copied from another computer or another Windows user profile.`n`n$($_.Exception.Message)",
            "Saved Array Security",
            "OK",
            "Warning"
        ) | Out-Null
    }
}

function Connect-SavedArrays {
    if (-not (Test-PurePrerequisitesForConnection)) {
        return
    }

    $Entries = @(
        $script:PureArrayEntries |
            Where-Object {
                $_.Status -ne "Connected"
            }
    )

    if ($Entries.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "There are no disconnected saved arrays to connect.",
            "Connect Saved Arrays",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    $UseSharedCredential = $false
    $SharedCredential = $null

    if ($Entries.Count -gt 1) {

        $CredentialMode =
            [System.Windows.MessageBox]::Show(
                "Do the saved arrays use the same username and password?`n`nYes = Enter credentials once and use them for all saved arrays.`nNo = Authenticate separately to each array.`nCancel = Stop.",
                "Saved Array Authentication",
                "YesNoCancel",
                "Question"
            )

        if ($CredentialMode -eq "Cancel") {
            return
        }

        $UseSharedCredential =
            $CredentialMode -eq "Yes"
    }

    if ($UseSharedCredential) {
        $SharedCredential =
            Get-Credential `
                -Message "Enter credentials for all saved arrays"

        if (-not $SharedCredential) {
            return
        }
    }

    Set-BusyState $true

    try {
        $Index = 0

        foreach ($Entry in $Entries) {
            $Index++

            $Endpoint = [string]$Entry.Endpoint

            Set-GlobalStatus `
                "Connecting to $Endpoint ($Index of $($Entries.Count))..."

            $Credential = $SharedCredential

            if (-not $Credential) {
                $Credential =
                    Get-Credential `
                        -Message "Authenticate to array $Endpoint"

                if (-not $Credential) {
                    $Entry.Status = "Saved - Not Connected"
                    $FlashArrayGrid.Items.Refresh()
                    continue
                }
            }

            $Connected = $false
            $LastError = $null

            try {
                $ConnectParams = @{
                    Endpoint    = $Endpoint
                    Credential  = $Credential
                    ErrorAction = "Stop"
                }

                if ($IgnoreCertificateCheckBox.IsChecked) {
                    $ConnectParams.IgnoreCertificateError = $true
                }

                $Array =
                    Connect-Pfa2Array @ConnectParams

                $Info =
                    Get-Pfa2Array `
                        -Array $Array `
                        -ErrorAction Stop

                $Connected = $true
            }
            catch {
                $LastError = $_.Exception.Message
            }

            # If the shared credential failed, allow this array to
            # use its own credential without restarting the workflow.
            if (-not $Connected -and $UseSharedCredential) {

                $DifferentCredential =
                    [System.Windows.MessageBox]::Show(
                        "The shared credential did not authenticate to:`n`n$Endpoint`n`n$LastError`n`nUse different credentials for this array?",
                        "Array Authentication Failed",
                        "YesNo",
                        "Warning"
                    )

                if ($DifferentCredential -eq "Yes") {

                    $Credential =
                        Get-Credential `
                            -Message "Authenticate separately to array $Endpoint"

                    if ($Credential) {
                        try {
                            $ConnectParams = @{
                                Endpoint    = $Endpoint
                                Credential  = $Credential
                                ErrorAction = "Stop"
                            }

                            if ($IgnoreCertificateCheckBox.IsChecked) {
                                $ConnectParams.IgnoreCertificateError = $true
                            }

                            $Array =
                                Connect-Pfa2Array @ConnectParams

                            $Info =
                                Get-Pfa2Array `
                                    -Array $Array `
                                    -ErrorAction Stop

                            $Connected = $true
                        }
                        catch {
                            $LastError = $_.Exception.Message
                        }
                    }
                }
            }

            if ($Connected) {

                $ArrayName =
                    if ($Info -and $Info.Name) {
                        [string]$Info.Name
                    }
                    else {
                        [string]$Entry.ArrayName
                    }

                $Entry.Username = [string]$Credential.UserName
                $Entry.ArrayName = $ArrayName
                $Entry.Status = "Connected"
                $Entry.Credential = $Credential
                $Entry.Connection = $Array

                $script:PureCredentials[$Endpoint] = $Credential
                $script:PureArrays[$Endpoint] = $Array
                $script:PureArrayInfo[$Endpoint] = $Info
            Save-SavedArrays # Persist successful array

                Write-ToolLog `
                    "Connected to saved Pure array $Endpoint as $($Credential.UserName)."
            }
            else {
                $Entry.Username = ""
                $Entry.Status = "Authentication Failed"
                $Entry.Credential = $null
                $Entry.Connection = $null

                Write-ToolLog `
                    "Unable to connect to saved array ${Endpoint}: $LastError" `
                    "WARN"
            }

            $FlashArrayGrid.Items.Refresh()
        }

        $ConnectedCount =
            @(
                $script:PureArrayEntries |
                    Where-Object {
                        $_.Status -eq "Connected"
                    }
            ).Count

        $script:PureConnected =
            $ConnectedCount -gt 0

        $script:PureValidationReady = $false

        if ($ApplyPureButton) {
            $ApplyPureButton.IsEnabled = $false
        }

        if ($ReviewConflictButton) {
            $ReviewConflictButton.IsEnabled = $false
        }

        Save-SavedArrays

        if ($ConnectedCount -gt 0) {
            $PureSummaryText.Text =
                "$ConnectedCount of $($script:PureArrayEntries.Count) array(s) connected. Run Validate / Dry Run when all required arrays are connected."

            Set-GlobalStatus `
                "$ConnectedCount array(s) connected."
        }
        else {
            $PureSummaryText.Text =
                "No saved arrays are connected."

            Set-GlobalStatus `
                "Saved array authentication did not complete."
        }
    }
    finally {
        Set-BusyState $false
    }

    Update-ValidationControls

    Refresh-ExistingHostGroups | Out-Null
}
function Get-FlashArrayList {
    @(
        $script:PureArrayEntries |
            Where-Object { $_.Status -eq "Connected" } |
            ForEach-Object { [string]$_.Endpoint }
    )
}

function Test-PurePrerequisitesForConnection {
    if (-not $script:PrereqsHealthy) {
        Test-ToolPrerequisites
        if (-not $script:PrereqsHealthy) {
            [System.Windows.MessageBox]::Show(
                "Pure registration prerequisites are not healthy. Open the Prerequisites tab and resolve all FAILED or MISSING items first.",
                "Prerequisites Required","OK","Warning"
            ) | Out-Null
            $MainTabs.SelectedIndex = 2
            return $false
        }
    }

    try {
        Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
        return $true
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Unable to import PureStoragePowerShellSDK2.`n`n$($_.Exception.Message)",
            "SDK Import Failed","OK","Error"
        ) | Out-Null
        return $false
    }
}

function Add-PureArrayConnection {
    if (-not (Test-PurePrerequisitesForConnection)) { return }

    $ExistingCount = $script:PureArrayEntries.Count
    $FirstEntry = if ($ExistingCount -gt 0) { $script:PureArrayEntries[0] } else { $null }

    [xml]$AddArrayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add Array"
        Height="380"
        Width="560"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="145"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2"
                   Text="Enter the array connection information. The connection is tested before the array is added."
                   TextWrapping="Wrap" Margin="0,0,0,14"/>

        <TextBlock Grid.Row="1" Grid.Column="0" Text="FQDN / Address:" VerticalAlignment="Center" Margin="0,0,8,8"/>
        <TextBox x:Name="EndpointTextBox" Grid.Row="1" Grid.Column="1" Height="26" Margin="0,0,0,8"/>


        <TextBlock x:Name="UsernameLabel" Grid.Row="2" Grid.Column="0" Text="Username:" VerticalAlignment="Center" Margin="0,0,8,8"/>
        <TextBox x:Name="UsernameTextBox" Grid.Row="2" Grid.Column="1" Height="26" Margin="0,0,0,8"/>

        <TextBlock x:Name="PasswordLabel" Grid.Row="3" Grid.Column="0" Text="Password:" VerticalAlignment="Center" Margin="0,0,8,8"/>
        <PasswordBox x:Name="PasswordBox" Grid.Row="3" Grid.Column="1" Height="26" Margin="0,0,0,8"/>

        <CheckBox x:Name="ReuseCredentialCheckBox"
                  Grid.Row="4"
                  Grid.Column="0"
                  Grid.ColumnSpan="2"
                  Content="Use credentials from first array"
                  IsChecked="False"
                  Margin="0,6,0,8"/>

        <TextBlock x:Name="CredentialHintText" Grid.Row="5" Grid.Column="0" Grid.ColumnSpan="2"
                   TextWrapping="Wrap" Margin="0,2,0,8"/>

        <TextBlock x:Name="TestStatusText" Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="2"
                   TextWrapping="Wrap" VerticalAlignment="Top"/>

        <StackPanel Grid.Row="7" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelButton" Content="Cancel" Width="90" Height="30" Margin="0,0,8,0" IsCancel="True"/>
            <Button x:Name="AddButton" Content="Add Array" Width="105" Height="30" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

    $Reader = New-Object System.Xml.XmlNodeReader $AddArrayXaml
    $Dialog = [Windows.Markup.XamlReader]::Load($Reader)
    $Dialog.Owner = $Window

    $EndpointTextBox = $Dialog.FindName("EndpointTextBox")
    $ReuseCredentialCheckBox = $Dialog.FindName("ReuseCredentialCheckBox")
    $UsernameLabel = $Dialog.FindName("UsernameLabel")
    $UsernameTextBox = $Dialog.FindName("UsernameTextBox")
    $PasswordLabel = $Dialog.FindName("PasswordLabel")
    $PasswordBox = $Dialog.FindName("PasswordBox")
    $CredentialHintText = $Dialog.FindName("CredentialHintText")
    $TestStatusText = $Dialog.FindName("TestStatusText")
    $CancelButton = $Dialog.FindName("CancelButton")
    $AddButton = $Dialog.FindName("AddButton")

    if ($ExistingCount -eq 0) {
        # First array must supply its own credential.
        $ReuseCredentialCheckBox.Visibility = "Collapsed"

        $UsernameLabel.Visibility = "Visible"
        $UsernameTextBox.Visibility = "Visible"
        $PasswordLabel.Visibility = "Visible"
        $PasswordBox.Visibility = "Visible"

        $UsernameTextBox.IsEnabled = $true
        $PasswordBox.IsEnabled = $true

        $CredentialHintText.Text = "This is the first array. Enter its username and password."

        $Dialog.Height = 330
    }
    else {
        # Second and subsequent arrays reuse the first credential by default.
        $ReuseCredentialCheckBox.Visibility = "Visible"
        $ReuseCredentialCheckBox.IsChecked = $true

        $UsernameLabel.Visibility = "Collapsed"
        $UsernameTextBox.Visibility = "Collapsed"
        $PasswordLabel.Visibility = "Collapsed"
        $PasswordBox.Visibility = "Collapsed"

        if ($FirstEntry) {
            $UsernameTextBox.Text = [string]$FirstEntry.Username
        }

        $CredentialHintText.Text = "Using the credential from the first array ($($FirstEntry.Username)). Uncheck the box to use a different username and password."

        $Dialog.Height = 335
    }

    $ReuseCredentialCheckBox.Add_Checked({
        if (-not $FirstEntry) {
            return
        }

        $UsernameLabel.Visibility = "Collapsed"
        $UsernameTextBox.Visibility = "Collapsed"
        $PasswordLabel.Visibility = "Collapsed"
        $PasswordBox.Visibility = "Collapsed"

        $UsernameTextBox.Text = [string]$FirstEntry.Username
        $PasswordBox.Clear()

        $CredentialHintText.Text = "Using the credential from the first array ($($FirstEntry.Username)). Uncheck the box to use a different username and password."

        $Dialog.Height = 335
    })

    $ReuseCredentialCheckBox.Add_Unchecked({
        if (-not $FirstEntry) {
            return
        }

        $UsernameLabel.Visibility = "Visible"
        $UsernameTextBox.Visibility = "Visible"
        $PasswordLabel.Visibility = "Visible"
        $PasswordBox.Visibility = "Visible"

        $UsernameTextBox.IsEnabled = $true
        $PasswordBox.IsEnabled = $true

        $UsernameTextBox.Clear()
        $PasswordBox.Clear()

        $CredentialHintText.Text = "Enter the username and password for this FlashArray."

        $Dialog.Height = 380

        $UsernameTextBox.Focus()
    })

    $CancelButton.Add_Click({
        $Dialog.DialogResult = $false
        $Dialog.Close()
    })

    $AddButton.Add_Click({
        $Endpoint = $EndpointTextBox.Text.Trim()
        if (-not $Endpoint) {
            $TestStatusText.Text = "Enter a FlashArray FQDN or management address."
            return
        }

        if (@($script:PureArrayEntries | Where-Object { $_.Endpoint -ieq $Endpoint }).Count -gt 0) {
            $TestStatusText.Text = "That array is already in the list."
            return
        }

        $Credential = $null
        if ($ExistingCount -gt 0 -and $ReuseCredentialCheckBox.IsChecked) {
            $Credential = $FirstEntry.Credential
        }
        else {
            $Username = $UsernameTextBox.Text.Trim()
            if (-not $Username) {
                $TestStatusText.Text = "Enter a username."
                return
            }
            if ($PasswordBox.SecurePassword.Length -eq 0) {
                $TestStatusText.Text = "Enter a password."
                return
            }
            $Credential = New-Object System.Management.Automation.PSCredential($Username,$PasswordBox.SecurePassword)
        }

        $AddButton.IsEnabled = $false
        $CancelButton.IsEnabled = $false
        $TestStatusText.Text = "Connecting to $Endpoint..."
        $Dialog.Dispatcher.Invoke([action]{}, "Background")

        try {
            $ConnectParams = @{
                Endpoint    = $Endpoint
                Credential  = $Credential
                ErrorAction = "Stop"
            }
            if ($IgnoreCertificateCheckBox.IsChecked) {
                $ConnectParams.IgnoreCertificateError = $true
            }

            $Array = Connect-Pfa2Array @ConnectParams
            $Info = Get-Pfa2Array -Array $Array -ErrorAction Stop
            $ArrayName = if ($Info -and $Info.Name) { [string]$Info.Name } else { "" }

            $Entry = [pscustomobject]@{
                Endpoint   = $Endpoint
                Username   = [string]$Credential.UserName
                ArrayName  = $ArrayName
                Status     = "Connected"
                Credential = $Credential
                Connection = $Array
            }

            $script:PureArrayEntries.Add($Entry)
            $script:PureCredentials[$Endpoint] = $Credential
            $script:PureArrays[$Endpoint] = $Array
            $script:PureArrayInfo[$Endpoint] = $Info
            $script:PureConnected = $true
            $script:PureValidationReady = $false
            $ApplyPureButton.IsEnabled = $false
            $ReviewConflictButton.IsEnabled = $false

            Write-ToolLog "Connected to Pure array $Endpoint as $($Credential.UserName)."
            $PureSummaryText.Text = "$($script:PureArrayEntries.Count) array(s) connected. Run Validate / Dry Run when all required arrays have been added."
            Set-GlobalStatus "Added and verified array $Endpoint."

            $Dialog.DialogResult = $true
            $Dialog.Close()
        }
        catch {
            $ErrorText = $_.Exception.Message
            Write-ToolLog "Pure array connection failed for ${Endpoint}: $ErrorText" "ERROR"
            $TestStatusText.Text = "Connection failed: $ErrorText"
            $AddButton.IsEnabled = $true
            $CancelButton.IsEnabled = $true
        }
    })

        $Dialog.Add_Loaded({
        $EndpointTextBox.Focus() | Out-Null
        $EndpointTextBox.SelectAll()
    })
$null = $Dialog.ShowDialog()

    Update-ValidationControls

    Refresh-ExistingHostGroups | Out-Null
}

function Get-LocalPureHosts {
    param($Array)
    $Hosts = @(Get-Pfa2Host -Array $Array -ErrorAction Stop)
    if ($Hosts.Count -gt 0 -and ($Hosts[0].PSObject.Properties.Name -contains "IsLocal")) {
        return @($Hosts | Where-Object { $_.IsLocal -ne $false })
    }
    return $Hosts
}

function Get-PureHostIqns {
    param($HostObject)
    $Values = @()
    foreach ($PropertyName in @("Iqns","IQNs","Iqn","IqnList")) {
        if ($HostObject.PSObject.Properties.Name -contains $PropertyName) {
            $Raw = $HostObject.$PropertyName
            if ($null -ne $Raw) { $Values += @($Raw) }
        }
    }
    @(
        $Values |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -like "iqn.*" } |
            Select-Object -Unique
    )
}

function Get-PureHostGroupName {
    param($HostObject)
    if ($HostObject.PSObject.Properties.Name -contains "HostGroup") {
        if ($HostObject.HostGroup -and $HostObject.HostGroup.Name) {
            return [string]$HostObject.HostGroup.Name
        }
    }
    if ($HostObject.PSObject.Properties.Name -contains "HostGroupName") {
        return [string]$HostObject.HostGroupName
    }
    return ""
}

function Test-HostOnArray {
    param(
        [string]$HostName,
        [string]$IQN,
        [array]$AllHosts
    )

    $NameMatch =
        $AllHosts |
        Where-Object { $_.Name -ieq $HostName } |
        Select-Object -First 1

    $IqnOwners = @()

    foreach ($ExistingHost in $AllHosts) {
        $ExistingIqns = @(Get-PureHostIqns $ExistingHost)

        if (@($ExistingIqns | Where-Object { $_ -ieq $IQN }).Count -gt 0) {
            $IqnOwners += $ExistingHost
        }
    }

    if ($NameMatch) {
        $NameIqns = @(Get-PureHostIqns $NameMatch)
        $SameIqn = @($NameIqns | Where-Object { $_ -ieq $IQN }).Count -gt 0

        $OtherOwners = @(
            $IqnOwners |
            Where-Object { $_.Name -ine $HostName }
        )

        if ($OtherOwners.Count -gt 0) {
            return [pscustomobject]@{
                State        = "IQN CONFLICT"
                ExistingHost = $NameMatch
                Message      = "IQN is also assigned to: $($OtherOwners.Name -join ', ')"
                Blocking     = $true
            }
        }

        if ($NameIqns.Count -eq 0) {
            return [pscustomobject]@{
                State        = "HOST EXISTS - IQN MISSING"
                ExistingHost = $NameMatch
                Message      = "Host exists but no IQN is configured."
                Blocking     = $true
            }
        }

        if (-not $SameIqn) {
            return [pscustomobject]@{
                State        = "NAME CONFLICT - DIFFERENT IQN"
                ExistingHost = $NameMatch
                Message      = "Host name exists with a different IQN."
                Blocking     = $true
            }
        }

        if ($NameIqns.Count -gt 1) {
            return [pscustomobject]@{
                State        = "REVIEW"
                ExistingHost = $NameMatch
                Message      = "Host name and IQN match, but the Pure host has additional IQNs."
                Blocking     = $true
            }
        }

        return [pscustomobject]@{
            State        = "MATCH"
            ExistingHost = $NameMatch
            Message      = "Host name and IQN match."
            Blocking     = $false
        }
    }

    if ($IqnOwners.Count -gt 0) {
        return [pscustomobject]@{
            State        = "IQN CONFLICT"
            ExistingHost = ($IqnOwners | Select-Object -First 1)
            Message      = "IQN is assigned to Pure host: $($IqnOwners.Name -join ', ')"
            Blocking     = $true
        }
    }

    return [pscustomobject]@{
        State        = "CREATE"
        ExistingHost = $null
        Message      = "Host name and IQN are available."
        Blocking     = $false
    }
}

function Get-HostGroupMode {
    if ($CreateHostGroupRadio.IsChecked) { return "Create" }
    if ($ExistingHostGroupRadio.IsChecked) { return "Existing" }
    return "None"
}

function Test-PureHostGroupPlan {
    $Mode = Get-HostGroupMode
    $GroupName = $HostGroupTextBox.Text.Trim()
    $States = @{}
    $Blocking = $false
    $Messages = @()

    if ($Mode -eq "None") {
        foreach ($Endpoint in $script:PureArrays.Keys) { $States[$Endpoint] = "N/A" }
        return [pscustomobject]@{ Mode="None"; Name=""; States=$States; Blocking=$false; Message="No host group selected." }
    }

    if (-not $GroupName) {
        return [pscustomobject]@{ Mode=$Mode; Name=""; States=$States; Blocking=$true; Message="Enter a host group name." }
    }

    foreach ($Endpoint in $script:PureArrays.Keys) {
        $Array = $script:PureArrays[$Endpoint]
        $Groups = @(Get-Pfa2HostGroup -Array $Array -ErrorAction Stop)
        $Group = $Groups | Where-Object { $_.Name -ieq $GroupName } | Select-Object -First 1

        if ($Mode -eq "Create") {
            if ($Group) {
                $States[$Endpoint] = "EXISTS"
                $Blocking = $true
                $Messages += "$Endpoint already has host group '$GroupName'."
            } else {
                $States[$Endpoint] = "CREATE"
            }
        } else {
            if ($Group) {
                $States[$Endpoint] = "MATCH"
            } else {
                $States[$Endpoint] = "CREATE/REPAIR"
            }
        }
    }

    if ($Mode -eq "Existing") {
        $FoundCount = @($States.Values | Where-Object { $_ -eq "MATCH" }).Count
        if ($FoundCount -eq 0) {
            $Blocking = $true
            $Messages += "The requested existing host group was not found on any selected array."
        }
    }

    if ($Messages.Count -eq 0) {
        $Messages += if ($Mode -eq "Create") {
            "Host group will be created on all selected arrays."
        } else {
            "Existing host group will be used; missing instances will be repaired."
        }
    }

    [pscustomobject]@{
        Mode=$Mode; Name=$GroupName; States=$States; Blocking=$Blocking; Message=($Messages -join " ")
    }
}

function Validate-PureRegistrationCore {
    $CurrentHosts = @(
        Get-HostList $HostTextBox.Text
    )

    $CurrentSignature =
        (
            $CurrentHosts |
            ForEach-Object {
                $_.ToLowerInvariant()
            } |
            Sort-Object
        ) -join "|"

    $AuditIsCurrent =
        $script:WindowsAuditComplete -and
        -not [string]::IsNullOrWhiteSpace(
            $script:WindowsAuditHostSignature
        ) -and
        $CurrentSignature -eq
        $script:WindowsAuditHostSignature

    if (-not $AuditIsCurrent) {

        $script:PureValidationReady = $false

        $ValidatePureButton.IsEnabled = $false
        $ApplyPureButton.IsEnabled = $false
        $ReviewConflictButton.IsEnabled = $false

        [System.Windows.MessageBox]::Show(
            "Run Audit Hosts successfully for the current Windows host list before Validate / Dry Run.",
            "Windows Audit Required",
            "OK",
            "Warning"
        ) | Out-Null

        Set-GlobalStatus `
            "Windows Audit required before Pure validation."

        return
    }

    if (-not $script:PureConnected -or $script:PureArrays.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Add and connect at least one array first.",
            "No Arrays Connected",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    Set-BusyState $true
    Set-GlobalStatus "Validating Pure host names, IQNs, and host-group state..."

    $script:PureResults.Clear()
    $script:PurePlan = @()
    $script:PureValidationReady = $false
    $ApplyPureButton.IsEnabled = $false

    try {
        $Mappings = @(Get-WindowsHostIqns)

        if ($Mappings.Count -eq 0) {
            throw "No host/IQN mappings were available."
        }

        $DuplicateIqns = @(
            $Mappings |
            Group-Object IQN |
            Where-Object Count -gt 1
        )

        if ($DuplicateIqns.Count -gt 0) {
            $Names = @()

            foreach ($Group in $DuplicateIqns) {
                $Names += "$($Group.Name): $($Group.Group.Host -join ', ')"
            }

            throw "Duplicate IQNs were discovered in the proposed host list. $($Names -join '; ')"
        }

        $GroupPlan = Test-PureHostGroupPlan
        $script:PureGroupPlan = $GroupPlan

        $AnyBlocked = [bool]$GroupPlan.Blocking
        $GroupName = $GroupPlan.Name

        foreach ($Endpoint in @(Get-FlashArrayList)) {
            if (-not $script:PureArrays.ContainsKey($Endpoint)) {
                throw "Array '$Endpoint' is not connected."
            }

            $Array = $script:PureArrays[$Endpoint]
            $AllHosts = @(Get-LocalPureHosts $Array)

            foreach ($Map in $Mappings) {
                $Check = Test-HostOnArray `
                    -HostName $Map.Host `
                    -IQN $Map.IQN `
                    -AllHosts $AllHosts

                $CurrentGroup =
                    if ($Check.ExistingHost) {
                        Get-PureHostGroupName $Check.ExistingHost
                    }
                    else {
                        ""
                    }

                $GroupBlocking = $false
                $GroupState = "N/A"

                if ($GroupName) {
                    if ($CurrentGroup -and $CurrentGroup -ine $GroupName) {
                        $GroupState = "Already in $CurrentGroup"
                        $GroupBlocking = $true
                    }
                    else {
                        $GroupState = "ADD/VERIFY $GroupName"
                    }
                }

                $Blocked = [bool]$Check.Blocking -or $GroupBlocking

                if ($Blocked) {
                    $AnyBlocked = $true
                }

                $ActionParts = @()

                if ($Check.State -eq "CREATE") {
                    $ActionParts += "Create host"
                }
                elseif ($Check.State -eq "MATCH") {
                    $ActionParts += "Reuse host"
                }
                else {
                    $ActionParts += "Review conflict"
                }

                if ($GroupName -and -not $GroupBlocking) {
                    $ActionParts += "Set host group"
                }

                $ResultText = $Check.Message

                if ($GroupBlocking) {
                    $ResultText += " Host group conflict."
                }

                $Row = [pscustomobject]@{
                    Host       = $Map.Host
                    IQN        = $Map.IQN
                    FlashArray = $Endpoint
                    State      = $Check.State
                    HostGroup  = $GroupState
                    Action     = ($ActionParts -join ", ")
                    Result     = $(if ($Blocked) {
                        "BLOCKED - $Endpoint - $ResultText"
                    }
                    else {
                        "READY - $Endpoint - $ResultText"
                    })
                }

                $script:PureResults.Add($Row)

                $script:PurePlan += [pscustomobject]@{
                    Host          = $Map.Host
                    IQN           = $Map.IQN
                    Endpoint      = $Endpoint
                    Array         = $Array
                    Check         = $Check
                    CurrentGroup  = $CurrentGroup
                    GroupBlocking = $GroupBlocking
                }
            }
        }

        $script:PureValidationReady = -not $AnyBlocked
        $ApplyPureButton.IsEnabled = $script:PureValidationReady

        if ($AnyBlocked) {
            $PureSummaryText.Text =
                "BLOCKED. One or more host-name, IQN, or host-group conflicts require review. No Pure changes have been made."

            Set-GlobalStatus "Pure validation blocked by conflicts."
            Write-ToolLog "Pure registration validation blocked by conflicts." "WARN"
        }
        else {
            $PureSummaryText.Text =
                "READY TO APPLY. Validation passed across $($script:PureArrays.Count) array(s). No volumes or LUN mappings will be changed."

            Set-GlobalStatus "Pure validation complete. Ready to apply."
            Write-ToolLog "Pure registration validation passed."
        }

        $PureResultsGrid.Items.Refresh()
    }
    catch {
        $script:PureValidationReady = $false
        $ApplyPureButton.IsEnabled = $false

        $ErrorText = $_.Exception.Message

        $PureSummaryText.Text = "Validation failed: $ErrorText"
        Set-GlobalStatus "Pure validation failed."
        Write-ToolLog "Pure validation failed: $ErrorText" "ERROR"

        [System.Windows.MessageBox]::Show(
            "Pure validation failed.`n`n$ErrorText`n`nNo Pure changes were made.",
            "Validation Failed",
            "OK",
            "Error"
        ) | Out-Null
    }
    finally {
        Set-BusyState $false
    }
}

function Validate-PureRegistration {
    $ArrayState = Get-ArrayConnectionSummary

    if ($ArrayState.Total -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Add or load at least one array first.",
            "No Arrays",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    if (-not $ArrayState.AllConnected) {
        $script:PureValidationReady = $false
        $script:LastPureValidationTime = $null
        $script:PureValidationReason = "BLOCKED"

        $ApplyPureButton.IsEnabled = $false

        [System.Windows.MessageBox]::Show(
            "All arrays in the Array list must be connected before Validate / Dry Run.`n`nConnected: $($ArrayState.Connected) of $($ArrayState.Total)",
            "All Arrays Must Be Connected",
            "OK",
            "Warning"
        ) | Out-Null

        Update-SessionStateBanner
        return
    }

    $script:LastPureValidationTime = $null
    $script:PureValidationReason = "RUNNING"

    Validate-PureRegistrationCore

    if ($script:PureValidationReady) {
        $script:LastPureValidationTime = Get-Date
        $script:PureValidationReason = "PASS"
    }
    else {
        $script:PureValidationReason = "BLOCKED"
    }

    Update-SessionStateBanner

    Update-ConflictReviewControls
}

function Get-PureChangePreview {
    $Lines = New-Object System.Collections.Generic.List[string]
    $Lines.Add("PURE REGISTRATION PLAN")
    $Lines.Add("")
    $Lines.Add("Arrays:")
    foreach ($Endpoint in @(Get-FlashArrayList)) { $Lines.Add("  $Endpoint") }
    $Lines.Add("")

    if ($script:PureGroupPlan) {
        if ($script:PureGroupPlan.Mode -eq "None") {
            $Lines.Add("Host Group: None")
        } else {
            $Lines.Add("Host Group: $($script:PureGroupPlan.Name)")
            foreach ($Endpoint in @(Get-FlashArrayList)) {
                $Lines.Add("  $Endpoint : $($script:PureGroupPlan.States[$Endpoint])")
            }
        }
    }

    $Lines.Add("")
    $Lines.Add("Host / Array actions:")
    foreach ($Plan in $script:PurePlan) {
        $Lines.Add("  $($Plan.Host) @ $($Plan.Endpoint)")
        $Lines.Add("    IQN: $($Plan.IQN)")
        $Lines.Add("    State: $($Plan.Check.State)")
    }

    $Lines.Add("")
    $Lines.Add("Out of scope / unchanged:")
    $Lines.Add("  Pods")
    $Lines.Add("  Protection Groups")
    $Lines.Add("  Volumes")
    $Lines.Add("  LUN assignments")
    $Lines.Add("  Volume connections")
        $Lines.Add("")
    $Lines.Add("Safety summary:")
    $Lines.Add("  Volume changes: 0")
    $Lines.Add("  LUN changes: 0")
    $Lines.Add("  Pod changes: 0")
    $Lines.Add("  Protection Group changes: 0")
    return ($Lines -join [Environment]::NewLine)
}

function Apply-PureRegistrationCore {
    if (-not $script:PureValidationReady) {
        [System.Windows.MessageBox]::Show(
            "Run Validate / Dry Run and resolve all BLOCKED items before applying changes.",
            "Validation Required","OK","Warning"
        ) | Out-Null
        return
    }

    $Confirm = "Yes"

    Set-BusyState $true
    try {
        $GroupPlan = $script:PureGroupPlan

        if ($GroupPlan -and $GroupPlan.Mode -ne "None") {
            foreach ($Endpoint in @(Get-FlashArrayList)) {
                if ($GroupPlan.States[$Endpoint] -in @("CREATE","CREATE/REPAIR")) {
                    New-Pfa2HostGroup -Array $script:PureArrays[$Endpoint] -Name $GroupPlan.Name -ErrorAction Stop | Out-Null
                    Write-ToolLog "Created host group '$($GroupPlan.Name)' on $Endpoint." "CHANGE"
                }
            }
        }

        foreach ($Plan in $script:PurePlan) {
            Set-GlobalStatus "Applying $($Plan.Host) on $($Plan.Endpoint)..."

            if ($Plan.Check.State -eq "CREATE") {
                New-Pfa2Host -Array $Plan.Array -Name $Plan.Host -Iqns $Plan.IQN -ErrorAction Stop | Out-Null
                Write-ToolLog "Created Pure host '$($Plan.Host)' on $($Plan.Endpoint) with IQN $($Plan.IQN)." "CHANGE"
            }

            if ($GroupPlan -and $GroupPlan.Mode -ne "None" -and $Plan.CurrentGroup -ine $GroupPlan.Name) {
                Update-Pfa2Host -Array $Plan.Array -Name $Plan.Host -HostGroupName $GroupPlan.Name -ErrorAction Stop | Out-Null
                Write-ToolLog "Added Pure host '$($Plan.Host)' to host group '$($GroupPlan.Name)' on $($Plan.Endpoint)." "CHANGE"
            }
        }

        $script:PureValidationReady = $false
        $ApplyPureButton.IsEnabled = $false
        Write-ToolLog "Pure registration writes completed. Starting verification."
    }
    catch {
        $ErrorText = $_.Exception.Message
        $script:PureValidationReady = $false
        $ApplyPureButton.IsEnabled = $false
        Write-ToolLog "Pure registration stopped after an error: $ErrorText" "ERROR"
        [System.Windows.MessageBox]::Show(
            "Pure registration stopped because an operation failed.`n`n$ErrorText`n`nNo further Pure changes will be attempted. Review the arrays and run Validate / Dry Run again.",
            "Pure Registration Failed","OK","Error"
        ) | Out-Null
        Set-GlobalStatus "Pure registration failed and stopped."
        return
    }
    finally {
        Set-BusyState $false
    }

    Validate-PureRegistration
    if ($script:PureValidationReady) {
        $PureSummaryText.Text = "VERIFIED. Host names and IQNs are consistent across all selected arrays. Host-group membership was revalidated. No volumes were changed."
        Set-GlobalStatus "Pure registration verified successfully."
        Write-ToolLog "Pure registration post-change verification completed successfully."
    }

    Write-ToolLog "Apply-PureRegistrationCore completed." "INFO"
}

function Apply-PureRegistration {
    Write-ToolLog `
        "Apply requested. Plan rows: $(@($script:PurePlan).Count)." `
        "INFO"
    if (-not $script:PureValidationReady) {
        [System.Windows.MessageBox]::Show(
            "Run Validate / Dry Run and resolve all BLOCKED items before applying changes.",
            "Validation Required",
            "OK",
            "Warning"
        ) | Out-Null

        return
    }

    if (-not (Test-AllArraysConnected)) {
        Invalidate-PureValidationState `
            -Reason "One or more arrays disconnected before Apply"

        [System.Windows.MessageBox]::Show(
            "All arrays in scope must still be connected. Reconnect them and run Validate / Dry Run again.",
            "Array Connection Changed",
            "OK",
            "Warning"
        ) | Out-Null

        return
    }

    $Summary = Get-EnhancedApplySummary
    $Preview = Get-PureChangePreview

    $ConfirmMessage = @"
$Summary

CHANGE PREVIEW

$Preview

Apply this Pure registration plan?

Yes = Apply
No  = Cancel
"@

    $RegistrationApproved = (Show-PureRegistrationConfirmation -Plan $script:PurePlan)

    Write-ToolLog "Apply confirmation returned: $RegistrationApproved." "INFO"

$Confirm =
        if ($RegistrationApproved) {
            "Yes"
        }
        else {
            "No"
        }

    if ($Confirm -ne "Yes") {
        Set-GlobalStatus "Pure registration cancelled."
        return
    }

    $PlanSnapshot = @($script:PurePlan)
    $GroupSnapshot = $script:PureGroupPlan

    Write-ToolLog "Entering Apply-PureRegistrationCore." "INFO"

    Apply-PureRegistrationCore

    # The legacy/core Apply finishes by re-running validation. Restore the
    # pre-write plan for explicit independent verification if necessary.
    if ($PlanSnapshot.Count -gt 0) {
        $script:PurePlan = $PlanSnapshot
    }

    if ($GroupSnapshot) {
        $script:PureGroupPlan = $GroupSnapshot
    }

    Write-ToolLog "Post-Apply verification started." "INFO"

    Test-PostApplyVerification | Out-Null
}

function Update-ConflictReviewButtonState {
    if (-not $ReviewConflictButton) { return }
    $Selected = $PureResultsGrid.SelectedItem
    $ReviewConflictButton.IsEnabled = [bool](
        $Selected -and ([string]$Selected.Result -like "BLOCKED*")
    )
}

function Get-PureHostConnections {
    param($Array,$HostObject)

    $HostName = [string]$HostObject.Name
    $HostGroupName = Get-PureHostGroupName $HostObject
    $AllConnections = @(Get-Pfa2Connection -Array $Array -ErrorAction Stop)

    $DirectConnections = @(
        $AllConnections | Where-Object { $_.Host -and $_.Host.Name -ieq $HostName }
    )
    $HostGroupConnections = @()
    if ($HostGroupName) {
        $HostGroupConnections = @(
            $AllConnections | Where-Object { $_.HostGroup -and $_.HostGroup.Name -ieq $HostGroupName }
        )
    }

    [pscustomobject]@{
        Host=$HostName; HostGroup=$HostGroupName
        DirectConnections=$DirectConnections.Count
        HostGroupConnections=$HostGroupConnections.Count
    }
}

function Get-PureConflictObjects {
    param($Array,[string]$Endpoint,[string]$DesiredHost,[string]$DesiredIQN)

    $Rows = @()
    foreach ($ExistingHost in @(Get-LocalPureHosts $Array)) {
        $ExistingIqns = @(Get-PureHostIqns $ExistingHost)
        $NameMatch = ([string]$ExistingHost.Name -ieq $DesiredHost)
        $IqnMatch = @($ExistingIqns | Where-Object { $_ -ieq $DesiredIQN }).Count -gt 0
        if (-not ($NameMatch -or $IqnMatch)) { continue }

        $Conn = Get-PureHostConnections -Array $Array -HostObject $ExistingHost
        $HostGroupName = [string]$Conn.HostGroup
        $Safe = (
            $Conn.DirectConnections -eq 0 -and
            $Conn.HostGroupConnections -eq 0 -and
            [string]::IsNullOrWhiteSpace($HostGroupName)
        )

        $Reason = ""
        if ($Conn.DirectConnections -gt 0) { $Reason += "$($Conn.DirectConnections) direct volume connection(s). " }
        if ($Conn.HostGroupConnections -gt 0) { $Reason += "$($Conn.HostGroupConnections) host-group volume connection(s). " }
        if ($HostGroupName) { $Reason += "Member of host group '$HostGroupName'. " }
        if ($Safe) { $Reason = "No storage connections or host-group membership detected." }

        $Rows += [pscustomobject]@{
            Endpoint=$Endpoint; ArrayObject=$Array; ExistingHost=[string]$ExistingHost.Name
            ExistingIQNs=($ExistingIqns -join "; "); DesiredHost=$DesiredHost; DesiredIQN=$DesiredIQN
            HostGroup=$HostGroupName; DirectConnections=$Conn.DirectConnections
            GroupConnections=$Conn.HostGroupConnections; NameMatchesDesired=$NameMatch
            DesiredIqnPresent=$IqnMatch; SafeToModify=$Safe; SafetyReason=$Reason
        }
    }
    return $Rows
}

function Confirm-PureConflictAction {
    param([string]$Title,[string]$Message)
    $FullMessage = "$Message`n`nBy clicking Yes, you confirm that you reviewed the existing Pure host object, are authorized to make this change, and understand that changing or deleting an initiator object can affect storage access.`n`nContinue?"
    return ([System.Windows.MessageBox]::Show($FullMessage,$Title,"YesNo","Warning") -eq "Yes")
}

function Set-PureConflictHostIQN {
    param($ConflictRow)

    if (-not $ConflictRow.SafeToModify) {
        [System.Windows.MessageBox]::Show(
            "This host object is not safe to modify.`n`n$($ConflictRow.SafetyReason)",
            "Modification Blocked","OK","Warning"
        ) | Out-Null
        return $false
    }
    if (-not $ConflictRow.NameMatchesDesired) {
        [System.Windows.MessageBox]::Show(
            "Replace IQN is allowed only when the existing Pure host name matches the discovered Windows host name.",
            "Replace IQN Not Applicable","OK","Information"
        ) | Out-Null
        return $false
    }

    $Cmd = Get-Command Update-Pfa2Host -ErrorAction Stop
    if (-not $Cmd.Parameters.ContainsKey("Iqns")) {
        [System.Windows.MessageBox]::Show(
            "The installed Pure SDK does not expose the expected -Iqns parameter on Update-Pfa2Host.",
            "SDK Operation Not Supported","OK","Error"
        ) | Out-Null
        return $false
    }

    $OtherOwners = @()
    foreach ($ExistingHost in @(Get-LocalPureHosts $ConflictRow.ArrayObject)) {
        if ([string]$ExistingHost.Name -ieq [string]$ConflictRow.ExistingHost) { continue }
        if (@(Get-PureHostIqns $ExistingHost | Where-Object { $_ -ieq $ConflictRow.DesiredIQN }).Count -gt 0) {
            $OtherOwners += [string]$ExistingHost.Name
        }
    }
    if ($OtherOwners.Count -gt 0) {
        [System.Windows.MessageBox]::Show(
            "The desired IQN is still owned by another Pure host: $($OtherOwners -join ', ')",
            "IQN Still In Use","OK","Warning"
        ) | Out-Null
        return $false
    }

    $Message = "FlashArray: $($ConflictRow.Endpoint)`n`nPure host: $($ConflictRow.ExistingHost)`nCurrent IQN(s): $($ConflictRow.ExistingIQNs)`nNew IQN: $($ConflictRow.DesiredIQN)`n`nThis operation replaces the IQN list on this Pure host object."
    if (-not (Confirm-PureConflictAction -Title "Confirm IQN Replacement" -Message $Message)) { return $false }

    try {
        Update-Pfa2Host -Array $ConflictRow.ArrayObject -Name $ConflictRow.ExistingHost -Iqns @($ConflictRow.DesiredIQN) -ErrorAction Stop | Out-Null
        Write-ToolLog "Replaced IQN on Pure host '$($ConflictRow.ExistingHost)' on $($ConflictRow.Endpoint)." "CHANGE"
        return $true
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "IQN update failed.`n`n$($_.Exception.Message)",
            "IQN Update Failed","OK","Error"
        ) | Out-Null
        return $false
    }
}

function Remove-SafePureConflictHost {
    param($ConflictRow)

    if (-not $ConflictRow.SafeToModify) {
        [System.Windows.MessageBox]::Show(
            "This host object cannot be deleted by the tool.`n`n$($ConflictRow.SafetyReason)",
            "Deletion Blocked","OK","Warning"
        ) | Out-Null
        return $false
    }

    $ExistingHost = @(Get-LocalPureHosts $ConflictRow.ArrayObject | Where-Object {
        $_.Name -ieq $ConflictRow.ExistingHost
    }) | Select-Object -First 1
    if (-not $ExistingHost) { return $false }

    $Conn = Get-PureHostConnections -Array $ConflictRow.ArrayObject -HostObject $ExistingHost
    if (
        $Conn.DirectConnections -gt 0 -or
        $Conn.HostGroupConnections -gt 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$Conn.HostGroup)
    ) {
        [System.Windows.MessageBox]::Show(
            "The host state changed and is no longer safe to delete.",
            "Deletion Safety Check Failed","OK","Warning"
        ) | Out-Null
        return $false
    }

    $Message = "FlashArray: $($ConflictRow.Endpoint)`n`nPure host to DELETE: $($ConflictRow.ExistingHost)`nIQN(s): $($ConflictRow.ExistingIQNs)`nDirect connections: $($ConflictRow.DirectConnections)`nHost-group connections: $($ConflictRow.GroupConnections)"
    if (-not (Confirm-PureConflictAction -Title "Confirm Pure Host Deletion" -Message $Message)) { return $false }

    try {
        Remove-Pfa2Host -Array $ConflictRow.ArrayObject -Name $ConflictRow.ExistingHost -ErrorAction Stop
        Write-ToolLog "Deleted stale Pure host '$($ConflictRow.ExistingHost)' from $($ConflictRow.Endpoint)." "CHANGE"
        return $true
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Pure host deletion failed.`n`n$($_.Exception.Message)",
            "Host Deletion Failed","OK","Error"
        ) | Out-Null
        return $false
    }
}

function Show-PureConflictReview {
    $Selected = $PureResultsGrid.SelectedItem

    if (
        -not $Selected -or
        [string]$Selected.Result -notlike "BLOCKED*"
    ) {
        return
    }

    $Endpoint = [string]$Selected.FlashArray

    if (-not $script:PureArrays.ContainsKey($Endpoint)) {
        [System.Windows.MessageBox]::Show(
            "The selected FlashArray is no longer connected. Reconnect and validate again.",
            "Array Not Connected",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    $Rows = @(
        Get-PureConflictObjects `
            -Array $script:PureArrays[$Endpoint] `
            -Endpoint $Endpoint `
            -DesiredHost $Selected.Host `
            -DesiredIQN $Selected.IQN
    )

    if ($Rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No matching host-name or IQN object was found on $Endpoint. The block may be related to host-group state; investigate manually.",
            "No Host Object Conflict",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    if ($Rows.Count -gt 1) {
        $Details = (
            $Rows |
            ForEach-Object {
                "$($_.ExistingHost) | IQN(s): $($_.ExistingIQNs) | $($_.SafetyReason)"
            }
        ) -join "`n"

        [System.Windows.MessageBox]::Show(
            "Multiple related host objects were found on $Endpoint. The tool will not choose between them automatically.`n`n$Details",
            "Multiple Conflicting Objects",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    $Choice = $Rows[0]

    $ExistingIqnsDisplay = [string]$Choice.ExistingIQNs

    if ([string]::IsNullOrWhiteSpace($ExistingIqnsDisplay)) {
        $ExistingIqnsDisplay = "None configured"
    }

    $HostGroupDisplay = [string]$Choice.HostGroup

    if ([string]::IsNullOrWhiteSpace($HostGroupDisplay)) {
        $HostGroupDisplay = "None"
    }

    if ($Selected.State -eq "HOST EXISTS - IQN MISSING") {
        $ConflictType = "HOST EXISTS - IQN MISSING"
        $YesAction = "Set IQN"
    }
    elseif ($Selected.State -eq "NAME CONFLICT - DIFFERENT IQN") {
        $ConflictType = "NAME CONFLICT - DIFFERENT IQN"
        $YesAction = "Replace IQN"
    }
    else {
        $ConflictType = [string]$Selected.State
        $YesAction = "Replace IQN"
    }

    $ResolverMessage = @"
Conflict Array:
$Endpoint

Conflict Type:
$ConflictType

Existing Host:
$($Choice.ExistingHost)

Existing IQN(s):
$ExistingIqnsDisplay

Required IQN:
$($Selected.IQN)

Host Group:
$HostGroupDisplay

Direct Connections:
$($Choice.DirectConnections)

Host-Group Connections:
$($Choice.GroupConnections)

Safe to Modify:
$($Choice.SafeToModify)

$($Choice.SafetyReason)

Yes = $YesAction
No = Delete Existing Host
Cancel = Keep / Investigate
"@

    $Action = [System.Windows.MessageBox]::Show(
        $ResolverMessage,
        "Resolve Pure Host Conflict - $Endpoint",
        "YesNoCancel",
        "Warning"
    )

    $Changed = $false

    if ($Action -eq "Yes") {
        $Changed = Set-PureConflictHostIQN $Choice
    }
    elseif ($Action -eq "No") {
        $Changed = Remove-SafePureConflictHost $Choice
    }

    if ($Changed) {
        Validate-PureRegistration
        Update-ConflictReviewButtonState
    }
}

# ------------------------------------------------------------
# GUI event handlers
# ------------------------------------------------------------

$HostTextBox.Add_TextChanged({

    if (-not $script:WindowsAuditComplete) {
        return
    }

    $CurrentHosts = @(
        Get-HostList $HostTextBox.Text
    )

    $CurrentSignature =
        (
            $CurrentHosts |
            ForEach-Object {
                $_.ToLowerInvariant()
            } |
            Sort-Object
        ) -join "|"

    if (
        $CurrentSignature -ne
        $script:WindowsAuditHostSignature
    ) {
        $script:WindowsAuditComplete = $false
        $script:WindowsAuditHostSignature = ""
        $script:PureValidationReady = $false

        $ValidatePureButton.IsEnabled = $false
        $ApplyPureButton.IsEnabled = $false
        $ReviewConflictButton.IsEnabled = $false

        $PureSummaryText.Text =
            "Windows Audit is stale because the host list changed. Run Audit Hosts again before Validate / Dry Run."

        Set-GlobalStatus `
            "Windows Audit: STALE - host list changed. Re-audit required."
    }
})
$ClearWindowsButton.Add_Click({

    $script:WindowsAuditComplete = $false
    $script:WindowsAuditHostSignature = ""
    $script:PureValidationReady = $false

    $ValidatePureButton.IsEnabled = $false
    $ApplyPureButton.IsEnabled = $false
    $ReviewConflictButton.IsEnabled = $false

    $PureSummaryText.Text =
        "Windows Audit results were cleared. Run Audit Hosts before Validate / Dry Run."

    Set-GlobalStatus `
        "Windows Audit: NOT RUN - re-audit required."
})
function Open-ToolDocument {
    param([Parameter(Mandatory)][string]$Name)

    $DocsPath = Join-Path (Split-Path -Parent $PSCommandPath) "Docs"
    $DocumentPath = Join-Path $DocsPath $Name

    if (-not (Test-Path $DocumentPath)) {
        [System.Windows.MessageBox]::Show(
            "Documentation not found:`n`n$DocumentPath",
            "Documentation Not Found","OK","Warning"
        ) | Out-Null
        return
    }

    Start-Process -FilePath $DocumentPath
}

function Show-ToolHelp {
    $DocsPath = Join-Path (Split-Path -Parent $PSCommandPath) "Docs"

    $Message = @"
iSCSI HOST TOOL v2.5.0 - QUICK START

1. Check Prerequisites.
2. Enter Windows hosts and select credentials.
3. Run Connectivity Preflight if desired.
4. Run Audit Hosts.
5. Remediate/reboot as required, then re-audit.
6. Add or reconnect all required arrays.
7. Select Host Group mode.
8. Run Validate / Dry Run.
9. Resolve blocked conflicts.
10. Review Show Change Preview.
11. Apply Pure registration only when the plan is correct.
12. Open iSCSI Connections; select Host, discovered Source NIC/IP, connected Pure Array, and discovered Target Port/IP from the smart selectors, then add mappings.
13. Run iSCSI Validate / Dry Run and review the change preview.
14. Apply iSCSI Connections only when the plan is correct.
15. Review iSCSI post-verification, including available Pure/MPIO runtime data.
16. Use Export All to package audit, validation, iSCSI plans/previews, summary, and log.
17. Use Reset Session when finished or before starting a different workflow.

SESSION STATE BANNER

The bottom status bar shows:
- Windows Audit state and timestamp
- Arrays connected / total
- Pure Validation state and timestamp
- Apply verification timestamp when available

ARRAY SECURITY

Saved array identities are encrypted with Windows DPAPI.
The saved file requires both:
- the same Windows user
- the same Windows computer

Credentials are never saved and must be re-entered after restart.

SAFETY BOUNDARY

The tool manages:
- Windows iSCSI / MPIO preparation
- Pure host objects
- optional host-group membership
- explicit Windows iSCSI target portals and persistent/multipath sessions

It does NOT manage:
- Pods
- Protection Groups
- volumes
- LUN assignment
- volume mappings
- Windows Failover Cluster creation
- Cluster Shared Volumes

BUTTONS

Connectivity Preflight
- checks Windows DNS/WinRM
- checks Array DNS/TCP 443

Export All
- creates a timestamped change package
- exports no credentials

Reset Session
- clears runtime credentials, audit state, array connections, validation state, and Apply readiness
- retains encrypted saved-array definitions

Remove Array
- removes only the local tool definition
- does not delete or modify the Pure array

Reconnect
- reauthenticates and retests one selected array

Full documentation:
$DocsPath
"@

    $Choice = [System.Windows.MessageBox]::Show(
        $Message + "`n`nOpen the Operations Guide?",
        "iSCSI Host Tool v2.5.0 - Help",
        "YesNo",
        "Information"
    )

    if ($Choice -eq "Yes") {
        Open-ToolDocument -Name "OPERATIONS-GUIDE.md"
    }
}
$FlashArrayGrid.Add_SelectionChanged({
    $HasSelection = [bool]$FlashArrayGrid.SelectedItem

    $RemoveArrayButton.IsEnabled = $HasSelection
    $RetestArrayButton.IsEnabled = $HasSelection
})

$RemoveArrayButton.Add_Click({
    Remove-SelectedArray
})

$RetestArrayButton.Add_Click({
    Retest-SelectedArray
})

$PreflightButton.Add_Click({
    Invoke-ConnectivityPreflight
})

$IscsiAddMappingButton.Add_Click({
    $HostName = [string]$IscsiHostComboBox.SelectedValue
    $SourceIP = [string]$IscsiSourceComboBox.SelectedValue
    $ArrayName = [string]$IscsiArrayComboBox.SelectedValue
    $TargetIP = [string]$IscsiTargetComboBox.SelectedValue

    if ([string]::IsNullOrWhiteSpace($HostName) -or
        [string]::IsNullOrWhiteSpace($SourceIP) -or
        [string]::IsNullOrWhiteSpace($ArrayName) -or
        [string]::IsNullOrWhiteSpace($TargetIP)) {
        [System.Windows.MessageBox]::Show(
            "Select a Host, Source NIC/IP, Pure Array, and Target Port/IP before adding the mapping.",
            "Incomplete iSCSI Mapping",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    $Existing = @(
        $script:IscsiConnectionResults |
            Where-Object {
                [string]$_.Host -ieq $HostName -and
                [string]$_.SourceIP -ieq $SourceIP -and
                [string]$_.Array -ieq $ArrayName -and
                [string]$_.TargetIP -ieq $TargetIP
            }
    )

    if ($Existing.Count -gt 0) {
        [System.Windows.MessageBox]::Show(
            "That exact Host / Source IP / Array / Target IP mapping already exists.",
            "Duplicate Mapping",
            "OK",
            "Information"
        ) | Out-Null
        return
    }

    $Row = New-IscsiMappingRow `
        -HostName $HostName `
        -SourceIP $SourceIP `
        -ArrayName $ArrayName `
        -TargetIP $TargetIP

    $Row.TargetIQN = [string]$IscsiTargetIqnTextBox.Text

    $script:IscsiConnectionResults.Add($Row)

    Invalidate-IscsiValidationState -Reason "Mapping added"

    $IscsiMappingGrid.SelectedIndex =
        $script:IscsiConnectionResults.Count - 1

    if ($IscsiMappingGrid.SelectedItem) {
        $IscsiMappingGrid.ScrollIntoView(
            $IscsiMappingGrid.SelectedItem
        )
    }
})

$IscsiRemoveMappingButton.Add_Click({
    if ($IscsiMappingGrid.SelectedItem) {
        $null =
            $script:IscsiConnectionResults.Remove(
                $IscsiMappingGrid.SelectedItem
            )

        Invalidate-IscsiValidationState `
            -Reason "Mapping removed"
    }
})

$IscsiBuildPlanButton.Add_Click({
    Build-IscsiRecommendedPlan
})

$IscsiRefreshChoicesButton.Add_Click({
    Refresh-IscsiSmartChoices
})

$IscsiHostComboBox.Add_SelectionChanged({
    Refresh-IscsiSourceChoices
})

$IscsiArrayComboBox.Add_SelectionChanged({
    Refresh-IscsiTargetChoices
})

$IscsiTargetComboBox.Add_SelectionChanged({
    Update-IscsiTargetIqnPreview
})

$IscsiValidateButton.Add_Click({
    Invoke-IscsiConnectionPreflight
})

$IscsiPreviewButton.Add_Click({
    Show-IscsiChangePreview
})

$IscsiApplyButton.Add_Click({
    Apply-IscsiConnections
})

$IscsiExportButton.Add_Click({
    Export-IscsiConnectionResults
})

if ($IscsiPersistentCheckBox) {
    $IscsiPersistentCheckBox.Add_Click({
        Invalidate-IscsiValidationState `
            -Reason "Persistence option changed"
    })
}

if ($IscsiMultipathCheckBox) {
    $IscsiMultipathCheckBox.Add_Click({
        Invalidate-IscsiValidationState `
            -Reason "Multipath option changed"
    })
}

if ($IscsiMinimumPathsTextBox) {
    $IscsiMinimumPathsTextBox.Add_TextChanged({
        Invalidate-IscsiValidationState `
            -Reason "Expected minimum path count changed"
    })
}

if ($MainTabs) {
    $MainTabs.Add_SelectionChanged({
        param($Sender,$EventArgs)

        try {
            # SelectionChanged is a routed WPF event. ComboBox/DataGrid selection
            # changes inside a tab bubble up to the TabControl. Only refresh when
            # the TabControl itself changed tabs; otherwise smart dropdown refreshes
            # can recursively trigger more discovery.
            if ($EventArgs -and
                $EventArgs.OriginalSource -ne $MainTabs) {
                return
            }

            $SelectedTab = $MainTabs.SelectedItem

            if ($SelectedTab -and
                [string]$SelectedTab.Header -eq "iSCSI Connections") {
                Refresh-IscsiSmartChoices
                Update-IscsiControls
            }
        }
        catch {
            Write-ToolLog `
                "Failed to refresh iSCSI smart choices: $($_.Exception.Message)" `
                "WARN"
        }
    })
}

$ViewLogButton.Add_Click({
    Open-CurrentToolLog
})

$AboutButton.Add_Click({
    Show-AboutTool
})
$ExportAllButton.Add_Click({
    Export-AllToolArtifacts
})

$ResetSessionButton.Add_Click({
    Reset-ToolSession
})
$WindowsCredentialButton.Add_Click({
    $script:WindowsCredential = Get-Credential `
        -Message "Enter an account with administrative PowerShell Remoting access to the Windows hosts."

    if ($script:WindowsCredential) {
        Set-GlobalStatus `
            "Windows credential selected: $($script:WindowsCredential.UserName)"
    }
})

$WindowsCurrentUserButton.Add_Click({
    $script:WindowsCredential = $null
    Set-GlobalStatus "Using current Windows credentials."
})

$AuditButton.Add_Click({
    Invoke-WindowsAudit
})

$ConfigureButton.Add_Click({
    $Hosts = @(Get-HostList $HostTextBox.Text)

    if ($Hosts.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Enter at least one hostname.",
            "No Hosts",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    $Message = @"
This will configure the following Pure Storage host-level best practices on $($Hosts.Count) Windows server(s):

- Microsoft iSCSI Initiator service = Automatic and Running
- Install Multipath I/O (MPIO), if missing
- Register PURE / FlashArray with Microsoft DSM
- Set global MPIO policy to Round Robin
- Apply Pure-recommended global MPIO timers
- Set Windows power plan to High Performance

The tool will NOT reboot any server automatically.

MPIO changes can require a reboot.

Continue?
"@

    $Confirm = [System.Windows.MessageBox]::Show(
        $Message,
        "Configure Pure Storage Best Practices",
        "YesNo",
        "Warning"
    )

    if ($Confirm -ne "Yes") {
        return
    }

    $script:WindowsResults.Clear()

    Set-BusyState $true

    try {
        $Index = 0

        foreach ($HostName in $Hosts) {
            $Index++

            Set-GlobalStatus `
                "Configuring $HostName ($Index of $($Hosts.Count))..."

            try {
                $Result = Invoke-HostCommand `
                    -ComputerName $HostName `
                    -ScriptBlock $ConfigureScript

                Add-WindowsResult `
                    -HostName $HostName `
                    -IQN ([string]$Result.IQN) `
                    -MSiSCSI ([string]$Result.MSiSCSI) `
                    -MPIO ([string]$Result.MPIO) `
                    -PureDSM ([string]$Result.PureDSM) `
                    -LBPolicy ([string]$Result.LBPolicy) `
                    -MPIOTimers ([string]$Result.MPIOTimers) `
                    -PowerPlan ([string]$Result.PowerPlan) `
                    -RebootRequired ([string]$Result.RebootRequired) `
                    -Status ([string]$Result.Status)

                Write-ToolLog `
                    "Configured Windows Pure baseline on ${HostName}. RebootRequired=$($Result.RebootRequired)." `
                    "CHANGE"
            }
            catch {
                Add-WindowsResult `
                    -HostName $HostName `
                    -Status $_.Exception.Message

                Write-ToolLog `
                    "Windows configuration failed for ${HostName}: $($_.Exception.Message)" `
                    "ERROR"
            }
        }

        $Reboots = 0

        foreach ($Row in $script:WindowsResults) {
            if ([string]$Row.RebootRequired -eq "Yes") {
                $Reboots++
            }
        }

        if ($Reboots -gt 0) {
            Set-GlobalStatus `
                "Configuration complete. $Reboots host(s) require a reboot."
        }
        else {
            Set-GlobalStatus `
                "Configuration complete. No reboot requirement was reported."
        }
    }
    finally {
        Set-BusyState $false
    }
})

$RebootButton.Add_Click({
    $Hosts = @(Get-HostList $HostTextBox.Text)

    if ($Hosts.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Enter at least one hostname.",
            "No Hosts",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    [xml]$SelectXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Select Hosts to Reboot"
        Height="520"
        Width="560"
        MinHeight="420"
        MinWidth="480"
        WindowStartupLocation="CenterOwner">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0"
                   Text="Select the servers to reboot."
                   Margin="0,0,0,10"/>

        <ListBox x:Name="HostList"
                 Grid.Row="1"
                 SelectionMode="Multiple"
                 Margin="0,0,0,10"/>

        <StackPanel Grid.Row="2"
                    Orientation="Horizontal"
                    Margin="0,0,0,10">
            <Button x:Name="SelectAllButton"
                    Content="Select All"
                    Width="100"
                    Height="30"
                    Margin="0,0,8,0"/>

            <Button x:Name="SelectNoneButton"
                    Content="Select None"
                    Width="100"
                    Height="30"/>
        </StackPanel>

        <StackPanel Grid.Row="3"
                    Orientation="Horizontal"
                    HorizontalAlignment="Right">
            <Button x:Name="CancelButton"
                    Content="Cancel"
                    Width="100"
                    Height="30"
                    Margin="0,0,8,0"/>

            <Button x:Name="ContinueButton"
                    Content="Continue"
                    Width="100"
                    Height="30"/>
        </StackPanel>
    </Grid>
</Window>
'@

    $SelectReader =
        New-Object System.Xml.XmlNodeReader $SelectXaml

    $SelectWindow =
        [Windows.Markup.XamlReader]::Load($SelectReader)

    $SelectWindow.Owner = $Window

    $HostList =
        $SelectWindow.FindName("HostList")

    $SelectAllButton =
        $SelectWindow.FindName("SelectAllButton")

    $SelectNoneButton =
        $SelectWindow.FindName("SelectNoneButton")

    $CancelButton =
        $SelectWindow.FindName("CancelButton")

    $ContinueButton =
        $SelectWindow.FindName("ContinueButton")

    foreach ($HostName in $Hosts) {
        [void]$HostList.Items.Add($HostName)
    }

    $SelectAllButton.Add_Click({
        $HostList.SelectAll()
    })

    $SelectNoneButton.Add_Click({
        $HostList.UnselectAll()
    })

    $CancelButton.Add_Click({
        $SelectWindow.DialogResult = $false
        $SelectWindow.Close()
    })

    $ContinueButton.Add_Click({
        if ($HostList.SelectedItems.Count -eq 0) {
            [System.Windows.MessageBox]::Show(
                "Select at least one server.",
                "No Servers Selected",
                "OK",
                "Information"
            ) | Out-Null

            return
        }

        $SelectWindow.DialogResult = $true
        $SelectWindow.Close()
    })

    if ($SelectWindow.ShowDialog() -ne $true) {
        return
    }

    $SelectedHosts = @()

    foreach ($Item in $HostList.SelectedItems) {
        $SelectedHosts += [string]$Item
    }

    $ServerList = (
        $SelectedHosts |
            ForEach-Object {
                "  - $_"
            }
    ) -join [Environment]::NewLine

    $ConfirmMessage = @"
The following servers will be rebooted:

$ServerList

This action will immediately restart the selected servers.

By clicking Yes, you confirm that:

- You are authorized to reboot these servers.
- The reboot is approved for the current maintenance/change window.
- You understand that active workloads or services can be interrupted.

Do you want to continue?
"@

    $Confirm = [System.Windows.MessageBox]::Show(
        $ConfirmMessage,
        "Confirm Authorized Server Reboot",
        "YesNo",
        "Warning"
    )

    if ($Confirm -ne "Yes") {
        Set-GlobalStatus "Reboot cancelled."
        return
    }

    [xml]$MonitorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Reboot Monitor"
        Height="520"
        Width="900"
        MinHeight="420"
        MinWidth="760"
        WindowStartupLocation="CenterOwner">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0"
                   Text="Monitoring reboot state. Down means WinRM is unavailable. Online is confirmed by a changed Windows boot time."
                   TextWrapping="Wrap"
                   Margin="0,0,0,10"/>

        <DataGrid x:Name="MonitorGrid"
                  Grid.Row="1"
                  AutoGenerateColumns="False"
                  IsReadOnly="True"
                  CanUserAddRows="False"
                  Margin="0,0,0,10">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Host"
                                    Binding="{Binding Host}"
                                    Width="150"/>

                <DataGridTextColumn Header="State"
                                    Binding="{Binding State}"
                                    Width="190"/>

                <DataGridTextColumn Header="Previous Boot Time"
                                    Binding="{Binding PreviousBoot}"
                                    Width="210"/>

                <DataGridTextColumn Header="Current Boot Time"
                                    Binding="{Binding CurrentBoot}"
                                    Width="210"/>

                <DataGridTextColumn Header="Elapsed"
                                    Binding="{Binding Elapsed}"
                                    Width="100"/>
            </DataGrid.Columns>
        </DataGrid>

        <ProgressBar x:Name="OverallProgress"
                     Grid.Row="2"
                     Height="20"
                     Minimum="0"
                     Maximum="100"
                     Margin="0,0,0,10"/>

        <DockPanel Grid.Row="3">
            <TextBlock x:Name="MonitorStatus"
                       DockPanel.Dock="Left"
                       VerticalAlignment="Center"
                       Text="Preparing reboot requests..."/>

            <Button x:Name="CloseMonitorButton"
                    DockPanel.Dock="Right"
                    Content="Close"
                    Width="100"
                    Height="30"
                    IsEnabled="False"/>
        </DockPanel>
            <Border x:Name="ToolVersionDisplay"
                HorizontalAlignment="Right"
                VerticalAlignment="Bottom"
                Margin="0,0,12,8"
                Background="#F4F4F4"
                BorderBrush="#D0D0D0"
                BorderThickness="1"
                Padding="7,3"
                Panel.ZIndex="1000">
            <TextBlock Text="v2.5.0"
                       Foreground="#606060"
                       FontSize="11"/>
        </Border>
</Grid>
</Window>
'@

    $MonitorReader =
        New-Object System.Xml.XmlNodeReader $MonitorXaml

    $MonitorWindow =
        [Windows.Markup.XamlReader]::Load($MonitorReader)

    $MonitorWindow.Owner = $Window

    $MonitorGrid =
        $MonitorWindow.FindName("MonitorGrid")

    $OverallProgress =
        $MonitorWindow.FindName("OverallProgress")

    $MonitorStatus =
        $MonitorWindow.FindName("MonitorStatus")

    $CloseMonitorButton =
        $MonitorWindow.FindName("CloseMonitorButton")

    $MonitorRows =
        New-Object System.Collections.ObjectModel.ObservableCollection[object]

    $MonitorGrid.ItemsSource = $MonitorRows

    $CloseMonitorButton.Add_Click({
        $MonitorWindow.Close()
    })

    $Trackers = @{}

    foreach ($HostName in $SelectedHosts) {
        $Row = [pscustomobject]@{
            Host         = $HostName
            State        = "Preparing"
            PreviousBoot = ""
            CurrentBoot  = ""
            Elapsed      = "00:00"
        }

        $MonitorRows.Add($Row)

        $Trackers[$HostName] = [pscustomobject]@{
            Host         = $HostName
            Row          = $Row
            PreviousBoot = $null
            StartTime    = Get-Date
            DownSeen     = $false
            Completed    = $false
            Failed       = $false
            TimedOut     = $false
        }
    }

    $MonitorWindow.Show()

    $MonitorWindow.Dispatcher.Invoke(
        [action]{},
        "Background"
    )

    Set-BusyState $true

    try {
        # Capture boot times before reboot.
        foreach ($HostName in $SelectedHosts) {
            $Tracker = $Trackers[$HostName]

            $Tracker.Row.State = "Reading boot time"

            $MonitorGrid.Items.Refresh()

            $MonitorWindow.Dispatcher.Invoke(
                [action]{},
                "Background"
            )

            try {
                $Boot = Invoke-HostCommand `
                    -ComputerName $HostName `
                    -ScriptBlock {
                        (
                            Get-CimInstance `
                                Win32_OperatingSystem `
                                -ErrorAction Stop
                        ).LastBootUpTime
                    }

                $Tracker.PreviousBoot = [datetime]$Boot

                $Tracker.Row.PreviousBoot =
                    $Tracker.PreviousBoot.ToString(
                        "yyyy-MM-dd HH:mm:ss"
                    )

                $Tracker.Row.State = "Ready to reboot"
            }
            catch {
                $Tracker.Failed = $true
                $Tracker.Row.State = "Pre-check failed"
                $Tracker.Row.PreviousBoot = "Unavailable"

                Write-ToolLog `
                    "Reboot pre-check failed for ${HostName}: $($_.Exception.Message)" `
                    "ERROR"
            }

            $MonitorGrid.Items.Refresh()
        }

        # Send reboot requests.
        foreach ($HostName in $SelectedHosts) {
            $Tracker = $Trackers[$HostName]

            if ($Tracker.Failed) {
                continue
            }

            $Tracker.Row.State = "Sending reboot"
            $MonitorStatus.Text =
                "Sending reboot request to $HostName..."

            $MonitorGrid.Items.Refresh()

            $MonitorWindow.Dispatcher.Invoke(
                [action]{},
                "Background"
            )

            try {
                $RestartParams = @{
                    ComputerName = $HostName
                    Force        = $true
                    ErrorAction  = "Stop"
                }

                if ($script:WindowsCredential) {
                    $RestartParams.Credential =
                        $script:WindowsCredential
                }

                Restart-Computer @RestartParams

                $Tracker.StartTime = Get-Date
                $Tracker.Row.State = "Reboot requested"

                Write-ToolLog `
                    "Reboot requested for $HostName." `
                    "CHANGE"
            }
            catch {
                $Tracker.Failed = $true
                $Tracker.Row.State =
                    "Reboot request failed"

                Write-ToolLog `
                    "Reboot request failed for ${HostName}: $($_.Exception.Message)" `
                    "ERROR"
            }

            $MonitorGrid.Items.Refresh()
        }

        $TimeoutMinutes = 15
        $PollSeconds = 3

        while ($true) {
            $Active = @(
                $Trackers.Values |
                    Where-Object {
                        -not $_.Completed -and
                        -not $_.Failed -and
                        -not $_.TimedOut
                    }
            )

            if ($Active.Count -eq 0) {
                break
            }

            foreach ($Tracker in $Active) {
                $Elapsed =
                    (Get-Date) - $Tracker.StartTime

                $Tracker.Row.Elapsed =
                    "{0:00}:{1:00}" -f
                        [int]$Elapsed.TotalMinutes,
                        $Elapsed.Seconds

                if (
                    $Elapsed.TotalMinutes -ge
                    $TimeoutMinutes
                ) {
                    $Tracker.TimedOut = $true
                    $Tracker.Row.State = "Timed out"
                    continue
                }

                $WsManAvailable = $false

                try {
                    if ($script:WindowsCredential) {
                        $null = Invoke-HostCommand `
                            -ComputerName $Tracker.Host `
                            -ScriptBlock {
                                $env:COMPUTERNAME
                            }
                    }
                    else {
                        $null = Test-WSMan `
                            -ComputerName $Tracker.Host `
                            -ErrorAction Stop
                    }

                    $WsManAvailable = $true
                }
                catch {
                    $WsManAvailable = $false
                }

                if (-not $WsManAvailable) {
                    $Tracker.DownSeen = $true
                    $Tracker.Row.State =
                        "Down - WinRM unavailable"

                    $Tracker.Row.CurrentBoot = ""

                    continue
                }

                try {
                    $Boot = Invoke-HostCommand `
                        -ComputerName $Tracker.Host `
                        -ScriptBlock {
                            (
                                Get-CimInstance `
                                    Win32_OperatingSystem `
                                    -ErrorAction Stop
                            ).LastBootUpTime
                        }

                    $CurrentBoot = [datetime]$Boot

                    $Tracker.Row.CurrentBoot =
                        $CurrentBoot.ToString(
                            "yyyy-MM-dd HH:mm:ss"
                        )

                    if (
                        $Tracker.PreviousBoot -and
                        $CurrentBoot -gt
                        $Tracker.PreviousBoot
                    ) {
                        $Tracker.Completed = $true

                        $Tracker.Row.State =
                            "Online - reboot confirmed"

                        Write-ToolLog `
                            "Reboot confirmed for $($Tracker.Host). New boot time: $CurrentBoot."
                    }
                    elseif ($Tracker.DownSeen) {
                        $Tracker.Row.State =
                            "Starting - WinRM online"
                    }
                    else {
                        $Tracker.Row.State =
                            "Waiting for shutdown"
                    }
                }
                catch {
                    if ($Tracker.DownSeen) {
                        $Tracker.Row.State = "Starting"
                    }
                    else {
                        $Tracker.Row.State =
                            "Waiting for shutdown"
                    }
                }
            }

            $CompletedCount = @(
                $Trackers.Values |
                    Where-Object Completed
            ).Count

            $FailedCount = @(
                $Trackers.Values |
                    Where-Object Failed
            ).Count

            $TimedOutCount = @(
                $Trackers.Values |
                    Where-Object TimedOut
            ).Count

            $FinishedCount =
                $CompletedCount +
                $FailedCount +
                $TimedOutCount

            $OverallProgress.Value =
                [math]::Round(
                    (
                        $FinishedCount /
                        $SelectedHosts.Count
                    ) * 100,
                    0
                )

            $MonitorStatus.Text =
                "Confirmed online: $CompletedCount | Failed: $FailedCount | Timed out: $TimedOutCount | Total: $($SelectedHosts.Count)"

            $MonitorGrid.Items.Refresh()

            $MonitorWindow.Dispatcher.Invoke(
                [action]{},
                "Background"
            )

            Start-Sleep -Seconds $PollSeconds
        }

        $CompletedCount = @(
            $Trackers.Values |
                Where-Object Completed
        ).Count

        $FailedCount = @(
            $Trackers.Values |
                Where-Object Failed
        ).Count

        $TimedOutCount = @(
            $Trackers.Values |
                Where-Object TimedOut
        ).Count

        $OverallProgress.Value = 100

        $MonitorStatus.Text =
            "Monitoring complete. Online: $CompletedCount | Failed: $FailedCount | Timed out: $TimedOutCount"

        $CloseMonitorButton.IsEnabled = $true

        $MonitorGrid.Items.Refresh()

        Set-GlobalStatus `
            "Reboot monitoring complete. Online: $CompletedCount. Failed: $FailedCount. Timed out: $TimedOutCount."
    }
    finally {
        Set-BusyState $false
    }
})

$ClearWindowsButton.Add_Click({
    $script:WindowsResults.Clear()
    Set-GlobalStatus "Windows results cleared."
})

$CopyIQNButton.Add_Click({
    $Rows = @(
        $script:WindowsResults |
            Where-Object {
                $_.IQN -like "iqn.*"
            }
    )

    if ($Rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "There are no IQNs to copy.",
            "No IQNs",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    $Text = (
        $Rows |
            ForEach-Object {
                "$($_.Host)`t$($_.IQN)"
            }
    ) -join [Environment]::NewLine

    [System.Windows.Clipboard]::SetText($Text)

    Set-GlobalStatus `
        "Copied $($Rows.Count) host/IQN mappings."
})

$ExportWindowsButton.Add_Click({
    if ($script:WindowsResults.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "There are no Windows results to export.",
            "No Results",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    $Dialog =
        New-Object Microsoft.Win32.SaveFileDialog

    $Dialog.Filter =
        "CSV files (*.csv)|*.csv|All files (*.*)|*.*"

    $Dialog.FileName =
        "Windows-Pure-Host-Audit-{0}.csv" -f
            (Get-Date -Format "yyyyMMdd-HHmmss")

    $Dialog.DefaultExt = ".csv"

    if ($Dialog.ShowDialog()) {
        $script:WindowsResults |
            Export-Csv `
                -Path $Dialog.FileName `
                -NoTypeInformation `
                -Encoding UTF8

        Set-GlobalStatus `
            "Exported Windows results to $($Dialog.FileName)"
    }
})

$WindowsDetailsButton.Add_Click({
    $Selected = $WindowsResultsGrid.SelectedItem

    if (-not $Selected) {
        [System.Windows.MessageBox]::Show(
            "Select a result row first.",
            "No Selection",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    $Details = @"
Host:             $($Selected.Host)
IQN:              $($Selected.IQN)
MSiSCSI:          $($Selected.MSiSCSI)
MPIO:             $($Selected.MPIO)
PURE DSM:         $($Selected.PureDSM)
Load Balance:     $($Selected.LBPolicy)
MPIO Timers:      $($Selected.MPIOTimers)
Power Plan:       $($Selected.PowerPlan)
Reboot Required:  $($Selected.RebootRequired)

Status:
$($Selected.Status)
"@

    [System.Windows.MessageBox]::Show(
        $Details,
        "Host Status - $($Selected.Host)",
        "OK",
        "Information"
    ) | Out-Null
})

$NoHostGroupRadio.Add_Checked({
    Invalidate-PureValidationState -Reason "Host-group mode changed"
    $HostGroupTextBox.IsEnabled = $false

    $script:PureValidationReady = $false
    $ApplyPureButton.IsEnabled = $false
})

$CreateHostGroupRadio.Add_Checked({
    Invalidate-PureValidationState -Reason "Host-group mode changed"
    $HostGroupTextBox.IsEnabled = $true

    $script:PureValidationReady = $false
    $ApplyPureButton.IsEnabled = $false
})

$ExistingHostGroupRadio.Add_Checked({
    Invalidate-PureValidationState -Reason "Host-group mode changed"
    $HostGroupTextBox.IsEnabled = $true

    $script:PureValidationReady = $false
    $ApplyPureButton.IsEnabled = $false
})

if ($HostGroupTextBox) {
    if ($HostGroupTextBox -is [System.Windows.Controls.ComboBox]) {
        $HostGroupTextBox.AddHandler(
            [System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
            [System.Windows.Controls.TextChangedEventHandler]{
    Invalidate-PureValidationState -Reason "Host-group name changed"
    $script:PureValidationReady = $false
    $ApplyPureButton.IsEnabled = $false
}
        )
        $HostGroupTextBox.Add_SelectionChanged({
    Invalidate-PureValidationState -Reason "Host-group name changed"
    $script:PureValidationReady = $false
    $ApplyPureButton.IsEnabled = $false
})
    }
    else {
        $HostGroupTextBox.Add_TextChanged({
    Invalidate-PureValidationState -Reason "Host-group name changed"
    $script:PureValidationReady = $false
    $ApplyPureButton.IsEnabled = $false
})
    }
}

$ConnectSavedArraysButton.Add_Click({
    Connect-SavedArrays
    Invalidate-PureValidationState -Reason "Saved arrays reconnected"
    Update-SessionStateBanner
})
$AddPureArrayButton.Add_Click({
    Add-PureArrayConnection
    Invalidate-PureValidationState -Reason "Array list/connection changed"
    Update-SessionStateBanner
})

$ValidatePureButton.Add_Click({
    Validate-PureRegistration
    Update-ConflictReviewButtonState
})

$PureResultsGrid.Add_SelectionChanged({
    Update-ConflictReviewButtonState
})

$ReviewConflictButton.Add_Click({
    Show-PureConflictReview
})

$ApplyPureButton.Add_Click({
    Apply-PureRegistration
})

$ExportPureButton.Add_Click({
    if ($script:PureResults.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Run Validate / Dry Run first.",
            "No Validation Results",
            "OK",
            "Information"
        ) | Out-Null

        return
    }

    $Dialog =
        New-Object Microsoft.Win32.SaveFileDialog

    $Dialog.Filter =
        "CSV files (*.csv)|*.csv|All files (*.*)|*.*"

    $Dialog.FileName =
        "Pure-Host-Registration-Validation-{0}.csv" -f
            (Get-Date -Format "yyyyMMdd-HHmmss")

    $Dialog.DefaultExt = ".csv"

    if ($Dialog.ShowDialog()) {
        $script:PureResults |
            Export-Csv `
                -Path $Dialog.FileName `
                -NoTypeInformation `
                -Encoding UTF8

        Set-GlobalStatus `
            "Exported Pure validation to $($Dialog.FileName)"
    }
})

$CheckPrereqButton.Add_Click({
    Test-ToolPrerequisites

    Set-GlobalStatus `
        "Prerequisite check complete."
})

$InstallPrereqButton.Add_Click({
    Install-MissingPrerequisites
})

$Window.Add_Closing({
    Write-ToolLog "Tool closed."
})

# ------------------------------------------------------------
# Startup
# ------------------------------------------------------------

Test-ToolPrerequisites

if (-not $script:PrereqsHealthy) {
    Set-GlobalStatus `
        "Ready. Review the Prerequisites tab before Pure registration."
}
else {
    Set-GlobalStatus `
        "Ready. Prerequisites passed."
}

Load-SavedArrays # Load saved endpoints
Update-SessionStateBanner

Update-ValidationControls

# v2.4.6 guarded validation refresh events
if ($HostTextBox) {
    $HostTextBox.Add_TextChanged({
        Update-ValidationControls
    })
}

if ($NoHostGroupRadio) {
    $NoHostGroupRadio.Add_Checked({
        Update-ValidationControls
    })
}

if ($CreateHostGroupRadio) {
    $CreateHostGroupRadio.Add_Checked({
        Update-ValidationControls
    })
}

if ($ExistingHostGroupRadio) {
    $ExistingHostGroupRadio.Add_Checked({
        Update-ValidationControls
    })
}

if ($HostGroupNameTextBox) {
    $HostGroupNameTextBox.Add_TextChanged({
        Update-ValidationControls
    })
}

Update-ValidationControls
# v2.4.7 conflict-review selection refresh
if ($PureResultsGrid) {
    $PureResultsGrid.Add_SelectionChanged({
        Update-ConflictReviewControls
    })
}

Update-ConflictReviewControls
if ($PureDetailsButton) {
    $PureDetailsButton.Add_Click({
        Show-PureChangePreviewDialog
    })
}
# v2.4.15 Existing Host Group population
if ($ExistingHostGroupRadio) {
    $ExistingHostGroupRadio.Add_Checked({
        $ConnectedArrays =
            @(Get-ConnectedPureArrayContexts)

        if ($ConnectedArrays.Count -eq 0) {
            [System.Windows.MessageBox]::Show(
                "You must connect to at least one array before selecting an existing host group.",
                "Existing Host Group",
                "OK",
                "Information"
            ) | Out-Null

            if ($NoHostGroupRadio) {
                $NoHostGroupRadio.IsChecked =
                    $true
            }

            Update-ValidationControls
            return
        }

        $Groups =
            @(Refresh-ExistingHostGroups -ShowMessages)

        if ($Groups.Count -gt 0) {
            $HostGroupTextBox.IsDropDownOpen =
                $true
        }

        Update-ValidationControls
    })
}

if ($HostGroupTextBox) {
    $HostGroupTextBox.Add_DropDownOpened({
        Refresh-ExistingHostGroups | Out-Null
    })
}
# v2.4.17 Clear Existing Host Group selection
if ($CreateHostGroupRadio) {
    $CreateHostGroupRadio.Add_Checked({
        Clear-ExistingHostGroupSelection
        Update-ValidationControls
    })
}

if ($NoHostGroupRadio) {
    $NoHostGroupRadio.Add_Checked({
        Clear-ExistingHostGroupSelection
        Update-ValidationControls
    })
}
if ($HelpButton) {
    $HelpButton.Add_Click({
        Open-iSCSIHostToolUserGuide
    })
}

Refresh-IscsiSmartChoices
Update-IscsiControls
$null = $Window.ShowDialog()
