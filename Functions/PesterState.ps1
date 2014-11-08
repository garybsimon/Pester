function New-PesterState
{
    param (
        [Parameter(Mandatory=$true)]
        [String]$Path,
        [String[]]$TagFilter,
        [String[]]$TestNameFilter,
        [System.Management.Automation.SessionState]$SessionState,
        [Switch]$Strict
    )

    if ($null -eq $SessionState) { $SessionState = $ExecutionContext.SessionState }

    New-Module -Name Pester -AsCustomObject -ScriptBlock {
        param (
            [String]$_path,
            [String[]]$_tagFilter,
            [String[]]$_testNameFilter,
            [System.Management.Automation.SessionState]$_sessionState,
            [Switch]$Strict
        )

        #public read-only
        $Path = $_path
        $TagFilter = $_tagFilter
        $TestNameFilter = $_testNameFilter

        $script:SessionState = $_sessionState
        $script:CurrentContext = ""
        $script:CurrentDescribe = ""
        $script:CurrentTest = ""
        $script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $script:MostRecentTimestamp = 0
        $script:CommandCoverage = @()
        $script:BeforeEach = @()
        $script:AfterEach = @()
        $script:Strict = $Strict

        $script:TestResult = @()

        function EnterDescribe ($Name)
        {
            if ($CurrentDescribe)
            {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "You already are in Describe, you cannot enter Describe twice"
            }
            $script:CurrentDescribe = $Name
        }

        function LeaveDescribe
        {
            if ( $CurrentContext ) {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "Cannot leave Describe before leaving Context"
            }

            $script:CurrentDescribe = $null
        }

        function EnterContext ($Name)
        {
            if ( -not $CurrentDescribe )
            {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "Cannot enter Context before entering Describe"
            }

            if ( $CurrentContext )
            {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "You already are in Context, you cannot enter Context twice"
            }

            if ($CurrentTest)
            {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "You already are in It, you cannot enter Context inside It"
            }

            $script:CurrentContext = $Name
        }

        function LeaveContext
        {
            if ($CurrentTest)
            {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "Cannot leave Context before leaving It"
            }

            $script:CurrentContext = $null
        }

        function EnterTest([string]$Name)
        {
            if (-not $script:CurrentDescribe)
            {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "Cannot enter It before entering Describe"
            }

            if ( $CurrentTest )
            {
                throw Microsoft.PowerShell.Utility\New-Object InvalidOperationException "You already are in It, you cannot enter It twice"
            }

            $script:CurrentTest = $Name
        }

        function LeaveTest
        {
            $script:CurrentTest = $null
        }

        function AddTestResult
        {
            param (
                [string]$Name,
                [ValidateSet("Failed","Passed","Skipped","Pending")]
                [string]$Result,
                [Nullable[TimeSpan]]$Time,
                [string]$FailureMessage,
                [string]$StackTrace,
                [string] $ParameterizedSuiteName,
                [System.Collections.IDictionary] $Parameters
            )
            $previousTime = $script:MostRecentTimestamp
            $script:MostRecentTimestamp = $script:Stopwatch.Elapsed

            if ($null -eq $Time)
            {
                $Time = $script:MostRecentTimestamp - $previousTime
            }

            if (-not $script:Strict)
            {
                $Passed = "Passed","Skipped","Pending" -contains $Result
            }
            else
            {
                $Passed = $Result -eq "Passed"
                if (($Result -eq "Skipped") -or ($Result -eq "Pending"))
                {
                    $FailureMessage = "The test failed because the test was executed in Strict mode and the result '$result' was translated to Failed."
                    $Result = "Failed"
                }

            }

            $Script:TestResult += Microsoft.PowerShell.Utility\New-Object -TypeName PsObject -Property @{
                Describe               = $CurrentDescribe
                Context                = $CurrentContext
                Name                   = $Name
                Passed                 = $Passed
                Result                 = $Result
                Time                   = $Time
                FailureMessage         = $FailureMessage
                StackTrace             = $StackTrace
                ParameterizedSuiteName = $ParameterizedSuiteName
                Parameters             = $Parameters
            } | Microsoft.PowerShell.Utility\Select-Object Describe, Context, Name, Result, Passed, Time, FailureMessage, StackTrace, ParameterizedSuiteName, Parameters
        }

        $ExportedVariables = "Path",
        "TagFilter",
        "TestNameFilter",
        "TestResult",
        "CurrentContext",
        "CurrentDescribe",
        "CurrentTest",
        "SessionState",
        "CommandCoverage",
        "BeforeEach",
        "AfterEach",
        "Strict"

        $ExportedFunctions = "EnterContext",
        "LeaveContext",
        "EnterDescribe",
        "LeaveDescribe",
        "EnterTest",
        "LeaveTest",
        "AddTestResult"

        Export-ModuleMember -Variable $ExportedVariables -function $ExportedFunctions
    } -ArgumentList $Path, $TagFilter, $TestNameFilter, $SessionState, $Strict |
    Add-Member -MemberType ScriptProperty -Name TotalCount -Value {
        @( $this.TestResult ).Count
    } -PassThru |
    Add-Member -MemberType ScriptProperty -Name PassedCount -Value {
        @( $this.TestResult | where { $_.Result -eq "Passed" } ).count
    } -PassThru |
    Add-Member -MemberType ScriptProperty -Name FailedCount -Value {
        @( $this.TestResult | where { $_.Result -eq "Failed" } ).count
    } -PassThru |
    Add-Member -MemberType ScriptProperty -Name SkippedCount -Value {
        @( $this.TestResult | where { $_.Result -eq "Skipped" } ).count
    } -PassThru |
    Add-Member -MemberType ScriptProperty -Name PendingCount -Value {
        @( $this.TestResult | where { $_.Result -eq "Pending" } ).count
    } -PassThru |
    Add-Member -MemberType ScriptProperty -Name Time -Value {
        $this.TestResult | foreach { [timespan]$total=0 } { $total = $total + ( $_.time ) } { [timespan]$total }
    } -PassThru |
    Add-Member -MemberType ScriptProperty -Name Scope -Value {
        if ($this.CurrentTest) { 'It' }
        elseif ($this.CurrentContext)  { 'Context' }
        elseif ($this.CurrentDescribe) { 'Describe' }
        else { $null }
    } -Passthru |
    Add-Member -MemberType ScriptProperty -Name ParentScope -Value {
        $parentScope = $null
        $scope = $this.Scope

        if ($scope -eq 'It' -and $this.CurrentContext)
        {
            $parentScope = 'Context'
        }

        if ($null -eq $parentScope -and $scope -ne 'Describe' -and $this.CurrentDescribe)
        {
            $parentScope = 'Describe'
        }

        return $parentScope
    } -PassThru
}
