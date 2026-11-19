<#
    OPTIMIZER GBZ - Painel de otimização gamer para Windows 10/11
    Autor: n0ctlow (GBZ)  |  Licença: MIT
    Windows 10 / 11  -  Windows PowerShell 5.1
    Abra pelo arquivo "Abrir Optimizer GBZ.bat" (ele pede permissão de administrador).
#>

param([switch]$Diag)

$script:Version = '1.0.0'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Se algo der errado ao abrir, mostra o erro na tela e salva num arquivo (em vez de sumir calado)
trap {
    # Depois que a janela abriu, um erro não fecha o programa: só vai para o registro
    if ($script:UiReady) { try { Write-Log "Erro: $($_.Exception.Message)" 'err' } catch {}; continue }
    $msg = "$($_.Exception.Message)`n`nLinha $($_.InvocationInfo.ScriptLineNumber): $("$($_.InvocationInfo.Line)".Trim())"
    try { Add-Content -LiteralPath "$env:TEMP\OptimizerGBZ-erro.txt" -Value "[$(Get-Date)] $msg" } catch {}
    [System.Windows.MessageBox]::Show("Erro ao abrir o Optimizer GBZ:`n`n$msg`n`nTire um print desta mensagem e abra uma issue no GitHub do projeto.", 'Optimizer GBZ', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    exit 1
}

# ------------------------------------------------------------------
# 1. Reabrir como administrador (e em modo STA, exigido pelo WPF)
# ------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSTA     = [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA'

if (-not $isAdmin -or -not $isSTA) {
    try {
        if ($Diag) { $argList = "-NoProfile -STA -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`" -Diag" }
        else       { $argList = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" }
        $ws = if ($Diag) { 'Normal' } else { 'Hidden' }
        if ($isAdmin) { Start-Process powershell.exe -ArgumentList $argList -WindowStyle $ws }
        else          { Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle $ws }
    } catch {
        [System.Windows.MessageBox]::Show("O Optimizer GBZ precisa de permissão de administrador.`n`nAbra de novo e clique em 'Sim' na janela de permissão.", 'Optimizer GBZ', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
    exit
}

# ------------------------------------------------------------------
# 2. Funções nativas do Windows (RAM, mouse, teclado, console)
# ------------------------------------------------------------------
if (-not ('GabTools' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class GabTools
{
    [DllImport("psapi.dll")] private static extern bool EmptyWorkingSet(IntPtr hProcess);
    [DllImport("ntdll.dll")] private static extern int NtSetSystemInformation(int infoClass, IntPtr info, int length);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokPriv newState, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SystemParametersInfo(uint action, uint param, int[] vparam, uint winIni);

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct TokPriv { public int Count; public long Luid; public int Attr; }

    private static bool EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x28, out token)) return false;
        try
        {
            TokPriv tp; tp.Count = 1; tp.Attr = 2; tp.Luid = 0;
            if (!LookupPrivilegeValue(null, name, out tp.Luid)) return false;
            return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally { CloseHandle(token); }
    }

    public static int TrimWorkingSets()
    {
        int count = 0;
        foreach (Process p in Process.GetProcesses())
        {
            try { if (EmptyWorkingSet(p.Handle)) count++; }
            catch { }
            finally { p.Dispose(); }
        }
        return count;
    }

    public static int PurgeStandbyList()
    {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        IntPtr buf = Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(buf, 4); return NtSetSystemInformation(80, buf, 4); }
        finally { Marshal.FreeHGlobal(buf); }
    }

    public static bool SetMouseAcceleration(bool enabled)
    {
        int[] v = enabled ? new int[] { 6, 10, 1 } : new int[] { 0, 0, 0 };
        return SystemParametersInfo(0x0004, 0, v, 3);
    }

    public static void SetKeyboard(uint delay, uint speed)
    {
        SystemParametersInfo(0x0017, delay, null, 3);
        SystemParametersInfo(0x000B, speed, null, 3);
    }
}
'@
}

# Moldura HUD desenhada por cima dos cards (cantos de mira que "travam" no card)
if (-not ('HudAdorner' -as [type])) {
    try {
        Add-Type -AssemblyName System.Xaml
        $wpfRefs = @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml') | ForEach-Object {
            $n = $_; ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $n } | Select-Object -First 1).Location
        }
        Add-Type -ReferencedAssemblies $wpfRefs -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

public class HudAdorner : Adorner
{
    public static readonly DependencyProperty ExtentProperty = DependencyProperty.Register("Extent", typeof(double), typeof(HudAdorner),
        new FrameworkPropertyMetadata(14.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty GlowProperty = DependencyProperty.Register("Glow", typeof(double), typeof(HudAdorner),
        new FrameworkPropertyMetadata(0.55, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Extent { get { return (double)GetValue(ExtentProperty); } set { SetValue(ExtentProperty, value); } }
    public double Glow { get { return (double)GetValue(GlowProperty); } set { SetValue(GlowProperty, value); } }

    private static readonly Brush Pink = MakeBrush(0xE8, 0x79, 0xF9);
    private static readonly Brush Cyan = MakeBrush(0x22, 0xD3, 0xEE);
    private static Brush MakeBrush(byte r, byte g, byte b) { var x = new SolidColorBrush(Color.FromRgb(r, g, b)); x.Freeze(); return x; }

    public HudAdorner(UIElement el) : base(el) { IsHitTestVisible = false; }

    protected override void OnRender(DrawingContext dc)
    {
        Size s = AdornedElement.RenderSize;
        if (s.Width < 40 || s.Height < 40) return;
        double e = Extent, o = 1, c = 12, w = s.Width, h = s.Height;
        Pen p = new Pen(Pink, 2);
        Pen q = new Pen(Cyan, 2);
        dc.PushOpacity(Glow);
        dc.DrawLine(p, new Point(o, o + e), new Point(o, o));
        dc.DrawLine(p, new Point(o, o), new Point(o + e, o));
        dc.DrawLine(p, new Point(w - o - c - e, o), new Point(w - o - c, o));
        dc.DrawLine(p, new Point(w - o - c, o), new Point(w - o, o + c));
        dc.DrawLine(p, new Point(w - o, o + c), new Point(w - o, o + c + e));
        dc.DrawLine(p, new Point(o, h - o - e), new Point(o, h - o));
        dc.DrawLine(p, new Point(o, h - o), new Point(o + e, h - o));
        dc.DrawLine(q, new Point(w - o, h - o - e), new Point(w - o, h - o));
        dc.DrawLine(q, new Point(w - o, h - o), new Point(w - o - e, h - o));
        dc.DrawRectangle(Cyan, null, new Rect(o + e + 8, o - 1, 22, 3));
        dc.DrawRectangle(Pink, null, new Rect(o + e + 34, o - 1, 6, 3));
        dc.Pop();
    }
}
'@
    } catch {}
}
$script:HudOk = [bool]('HudAdorner' -as [type])

if (-not ('GabColor' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GabColor
{
    [DllImport("gdi32.dll")] private static extern bool SetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateDC(string driver, string device, string output, IntPtr init);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool EnumDisplayDevices(string device, uint num, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("Magnification.dll")] private static extern bool MagInitialize();
    [DllImport("Magnification.dll")] private static extern bool MagUninitialize();
    [DllImport("Magnification.dll")] private static extern bool MagSetFullscreenColorEffect(float[] effect);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    // Brilho, contraste, gama e temperatura: tabela de cores (gamma ramp) de cada monitor
    public static int ApplyGamma(double bright, double contrast, double gamma, double rm, double gm, double bm)
    {
        ushort[] ramp = new ushort[768];
        double[] mul = { rm, gm, bm };
        for (int c = 0; c < 3; c++)
        {
            for (int i = 0; i < 256; i++)
            {
                double v = i / 255.0;
                v = (v - 0.5) * contrast + 0.5;
                v = v * bright;
                if (v < 0) v = 0; if (v > 1) v = 1;
                v = Math.Pow(v, 1.0 / gamma);
                v = v * mul[c];
                if (v < 0) v = 0; if (v > 1) v = 1;
                ramp[c * 256 + i] = (ushort)(v * 65535);
            }
        }
        int ok = 0;
        DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
        dd.cb = Marshal.SizeOf(dd);
        for (uint n = 0; EnumDisplayDevices(null, n, ref dd, 0); n++)
        {
            if ((dd.StateFlags & 1) != 0)
            {
                IntPtr hdc = CreateDC(dd.DeviceName, null, null, IntPtr.Zero);
                if (hdc != IntPtr.Zero)
                {
                    if (SetDeviceGammaRamp(hdc, ramp)) ok++;
                    DeleteDC(hdc);
                }
            }
            dd.cb = Marshal.SizeOf(dd);
        }
        return ok;
    }

    // Saturação: matriz de cor aplicada na tela inteira pelo Windows
    private static bool magReady = false;
    public static bool SetSaturation(double s)
    {
        if (!magReady) { magReady = MagInitialize(); if (!magReady) return false; }
        float fs = (float)s;
        float r = (float)((1 - s) * 0.2126), g = (float)((1 - s) * 0.7152), b = (float)((1 - s) * 0.0722);
        float[] m = {
            r + fs, r,      r,      0, 0,
            g,      g + fs, g,      0, 0,
            b,      b,      b + fs, 0, 0,
            0,      0,      0,      1, 0,
            0,      0,      0,      0, 1 };
        return MagSetFullscreenColorEffect(m);
    }

    public static void ResetSaturation()
    {
        if (!magReady) return;
        SetSaturation(1.0);
        MagUninitialize();
        magReady = false;
    }
}
'@
}

if ($Diag) { Write-Host 'MODO DIAGNÓSTICO: erros aparecem nesta janela. Não feche ela.' -ForegroundColor Yellow }
else { try { [void][GabTools]::ShowWindow([GabTools]::GetConsoleWindow(), 0) } catch {} }

# ------------------------------------------------------------------
# 3. Interface (XAML)
# ------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Optimizer GBZ" Width="1340" Height="860" MinWidth="1120" MinHeight="720"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#120D21" FontFamily="Segoe UI" Foreground="#FFFFFF">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="46" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <LinearGradientBrush x:Key="PurpleGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#7C3AED" Offset="0"/>
      <GradientStop Color="#D946EF" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="HeroGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#5B21B6" Offset="0"/>
      <GradientStop Color="#A21CAF" Offset="0.6"/>
      <GradientStop Color="#DB2777" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="GaugeGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#A855F7" Offset="0"/>
      <GradientStop Color="#EC4899" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="GreenGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#39FF88" Offset="0"/>
      <GradientStop Color="#00D9A3" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="GreenFade" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#6639FF88" Offset="0"/>
      <GradientStop Color="#0039FF88" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="PinkFade" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#77D946EF" Offset="0"/>
      <GradientStop Color="#00D946EF" Offset="1"/>
    </LinearGradientBrush>
    <DrawingBrush x:Key="ScanBrush" TileMode="Tile" Viewport="0,0,4,3" ViewportUnits="Absolute" Viewbox="0,0,4,3" ViewboxUnits="Absolute">
      <DrawingBrush.Drawing>
        <GeometryDrawing Brush="#14FFFFFF">
          <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,4,1"/></GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>
    <DrawingBrush x:Key="GridBrush" TileMode="Tile" Viewport="0,0,44,44" ViewportUnits="Absolute" Viewbox="0,0,44,44" ViewboxUnits="Absolute">
      <DrawingBrush.Drawing>
        <GeometryDrawing Brush="#0EFFFFFF">
          <GeometryDrawing.Geometry>
            <GeometryGroup>
              <RectangleGeometry Rect="0,0,44,1"/>
              <RectangleGeometry Rect="0,0,1,44"/>
            </GeometryGroup>
          </GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>
    <LinearGradientBrush x:Key="ScanBarGrad" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#00D946EF" Offset="0"/>
      <GradientStop Color="#1FD946EF" Offset="0.85"/>
      <GradientStop Color="#66E879F9" Offset="0.97"/>
      <GradientStop Color="#00D946EF" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="HueGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#FF0000" Offset="0"/>
      <GradientStop Color="#FFFF00" Offset="0.2"/>
      <GradientStop Color="#00FF00" Offset="0.4"/>
      <GradientStop Color="#00FFFF" Offset="0.6"/>
      <GradientStop Color="#0000FF" Offset="0.8"/>
      <GradientStop Color="#FF00FF" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="WaveGrad" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#007C3AED" Offset="0"/>
      <GradientStop Color="#A855F7" Offset="0.35"/>
      <GradientStop Color="#D946EF" Offset="0.7"/>
      <GradientStop Color="#00D946EF" Offset="1"/>
    </LinearGradientBrush>

    <!-- Botão base -->
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Background" Value="#251C42"/>
      <Setter Property="BorderBrush" Value="#3A2E66"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="3" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#D946EF"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="bd" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.03" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="bd" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.03" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="bd" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.18"/>
                      <DoubleAnimation Storyboard.TargetName="bd" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.75"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource PurpleGrad}"/>
      <Setter Property="BorderBrush" Value="#F0ABFC"/>
      <Setter Property="FontWeight" Value="Black"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="22,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="root" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="2" RenderTransformOrigin="0.5,0.5">
                <Border.RenderTransform><SkewTransform AngleX="-14"/></Border.RenderTransform>
              </Border>
              <Rectangle x:Name="shine" Width="18" HorizontalAlignment="Left" Fill="#40FFFFFF" IsHitTestVisible="False" RenderTransformOrigin="0.5,0.5" Opacity="0">
                <Rectangle.RenderTransform>
                  <TransformGroup><SkewTransform AngleX="-14"/><TranslateTransform X="0"/></TransformGroup>
                </Rectangle.RenderTransform>
              </Rectangle>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="White"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.04" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.04" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="shine" Storyboard.TargetProperty="Opacity" From="1" To="0" Duration="0:0:0.5"/>
                      <DoubleAnimation Storyboard.TargetName="shine" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.X)" From="-10" To="260" Duration="0:0:0.5"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.18"/>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.75"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="root" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="RoundBtn" TargetType="Button">
      <Setter Property="Width" Value="44"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2E2452"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="6,0,6,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="root" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <Ellipse x:Name="el" Fill="{TemplateBinding Background}" Stroke="#5B45A8" StrokeThickness="1"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="el" Property="Stroke" Value="#E879F9"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.12" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.12" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.15"/>
                      <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="root" Property="Opacity" Value="0.7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#3A1028"/>
      <Setter Property="BorderBrush" Value="#7A1F4A"/>
      <Setter Property="Foreground" Value="#FF8FB8"/>
    </Style>
    <Style x:Key="Glass" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#33FFFFFF"/>
      <Setter Property="BorderBrush" Value="#66FFFFFF"/>
    </Style>
    <Style x:Key="Nav" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#B9B0DA"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="14,1,14,1"/>
      <Setter Property="FontSize" Value="14"/>
    </Style>

    <!-- Botão de play redondo com onda pulsando -->
    <Style x:Key="PlayBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Width" Value="62"/>
      <Setter Property="Height" Value="62"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Ellipse x:Name="ring" Stroke="White" StrokeThickness="2" Opacity="0" RenderTransformOrigin="0.5,0.5">
                <Ellipse.RenderTransform>
                  <ScaleTransform ScaleX="1" ScaleY="1"/>
                </Ellipse.RenderTransform>
              </Ellipse>
              <Ellipse x:Name="circle" Fill="White" RenderTransformOrigin="0.5,0.5">
                <Ellipse.RenderTransform>
                  <ScaleTransform ScaleX="1" ScaleY="1"/>
                </Ellipse.RenderTransform>
                <Ellipse.Effect>
                  <DropShadowEffect Color="#F0ABFC" BlurRadius="26" ShadowDepth="0" Opacity="0.9"/>
                </Ellipse.Effect>
              </Ellipse>
              <Path Data="M 0,0 L 17,10.5 L 0,21 Z" Fill="#7C3AED" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="5,0,0,0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard x:Name="ringPulse">
                    <Storyboard RepeatBehavior="Forever">
                      <DoubleAnimation Storyboard.TargetName="ring" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="1.6" Duration="0:0:1.2"/>
                      <DoubleAnimation Storyboard.TargetName="ring" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" From="1" To="1.6" Duration="0:0:1.2"/>
                      <DoubleAnimation Storyboard.TargetName="ring" Storyboard.TargetProperty="Opacity" From="0.8" To="0" Duration="0:0:1.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="circle" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.1" Duration="0:0:0.15"/>
                      <DoubleAnimation Storyboard.TargetName="circle" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.1" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <StopStoryboard BeginStoryboardName="ringPulse"/>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="circle" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.2"/>
                      <DoubleAnimation Storyboard.TargetName="circle" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="circle" Property="Opacity" Value="0.8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#B9B0DA"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="3">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2E2452"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WinClose" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="3">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E11D48"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ChromeIcon" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#E879F9"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#D91C1533"/>
      <Setter Property="BorderBrush" Value="#2C2350"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="20"/>
      <Setter Property="Margin" Value="0,0,16,16"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="#5B45A8"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Hero" TargetType="Border" BasedOn="{StaticResource Card}">
      <Setter Property="Background" Value="{StaticResource HeroGrad}"/>
      <Setter Property="BorderBrush" Value="#C084FC"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="28,24"/>
    </Style>
    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="Background" Value="#2E2452"/>
      <Setter Property="CornerRadius" Value="2"/>
      <Setter Property="Padding" Value="9,3"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9D93C4"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="Desc" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9D93C4"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,12"/>
    </Style>
    <Style x:Key="Big" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="Black"/>
      <Setter Property="Margin" Value="0,8,0,0"/>
    </Style>
    <Style x:Key="GaugeNum" TargetType="TextBlock">
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="Black"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="GaugeSub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#9D93C4"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="Margin" Value="0,2,14,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="ProfileCard" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
      <Setter Property="Background" Value="#241B40"/>
      <Setter Property="BorderBrush" Value="#33295A"/>
    </Style>

    <Style x:Key="NeonSlider" TargetType="Slider">
      <Setter Property="Height" Value="26"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center">
              <Border Height="6" CornerRadius="3" Background="#2A2148"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="6" CornerRadius="3" Background="{StaticResource GaugeGrad}"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Width="20" Height="20" Fill="White" Stroke="#D946EF" StrokeThickness="4"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="HueSlider" TargetType="Slider">
      <Setter Property="Height" Value="26"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center">
              <Border Height="10" CornerRadius="5">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#FF0000" Offset="0"/>
                    <GradientStop Color="#FFFF00" Offset="0.17"/>
                    <GradientStop Color="#00FF00" Offset="0.33"/>
                    <GradientStop Color="#00FFFF" Offset="0.5"/>
                    <GradientStop Color="#0000FF" Offset="0.67"/>
                    <GradientStop Color="#FF00FF" Offset="0.83"/>
                    <GradientStop Color="#FF0000" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Width="22" Height="22" Fill="White" Stroke="#120D21" StrokeThickness="3"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="4" Background="#2A2148"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" Background="{StaticResource GaugeGrad}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Interruptor animado -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="row" Background="#241B40" BorderBrush="#33295A" BorderThickness="1" CornerRadius="4" Padding="16,11">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ContentPresenter VerticalAlignment="Center" Margin="0,0,14,0"/>
                <Border x:Name="track" Grid.Column="1" Width="46" Height="24" CornerRadius="3" VerticalAlignment="Center">
                  <Border.Background>
                    <SolidColorBrush Color="#3A2E66"/>
                  </Border.Background>
                  <Rectangle x:Name="knob" Width="18" Height="18" RadiusX="2" RadiusY="2" Fill="White" HorizontalAlignment="Left" Margin="3,0,3,0">
                    <Rectangle.RenderTransform>
                      <TranslateTransform X="0"/>
                    </Rectangle.RenderTransform>
                  </Rectangle>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="row" Property="BorderBrush" Value="#5B45A8"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="row" Property="BorderBrush" Value="#7C3AED"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="20" Duration="0:0:0.2">
                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.4"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#C026D3" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.2">
                        <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.4"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#3A2E66" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="8"/>
          <Setter Property="MinWidth" Value="8"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="True">
                  <Track.Thumb>
                    <Thumb>
                      <Thumb.Template>
                        <ControlTemplate TargetType="Thumb">
                          <Border CornerRadius="4" Background="#4C3D8A" Margin="1,0,1,0"/>
                        </ControlTemplate>
                      </Thumb.Template>
                    </Thumb>
                  </Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowBackground" Value="Transparent"/>
      <Setter Property="AlternatingRowBackground" Value="#14FFFFFF"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="RowHeight" Value="34"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#241B40"/>
      <Setter Property="Foreground" Value="#9D93C4"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#7C3AED"/>
          <Setter Property="Foreground" Value="White"/>
          <Setter Property="BorderBrush" Value="#7C3AED"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Border x:Name="rootBorder" BorderBrush="#2C2350" BorderThickness="1">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="250"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- FUNDO: grade HUD, brilhos, ondas e partículas -->
    <Rectangle Grid.ColumnSpan="2" Fill="{StaticResource GridBrush}" IsHitTestVisible="False"/>
    <Canvas x:Name="bgParticles" Grid.ColumnSpan="2" IsHitTestVisible="False" ClipToBounds="True" Visibility="Collapsed"/>
    <Canvas Grid.ColumnSpan="2" IsHitTestVisible="False" ClipToBounds="True">
      <Ellipse x:Name="bgOrb1" Width="760" Height="760" Canvas.Left="620" Canvas.Top="-300">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#557C3AED" Offset="0"/>
            <GradientStop Color="#007C3AED" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform>
          <TranslateTransform X="0" Y="0"/>
        </Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse x:Name="bgOrb2" Width="640" Height="640" Canvas.Left="-160" Canvas.Top="420">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#44D946EF" Offset="0"/>
            <GradientStop Color="#00D946EF" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform>
          <TranslateTransform X="0" Y="0"/>
        </Ellipse.RenderTransform>
      </Ellipse>
      <Canvas x:Name="bgWaves">
        <Canvas.RenderTransform>
          <TranslateTransform X="0"/>
        </Canvas.RenderTransform>
        <Path Data="M -200,560 C 200,380 520,760 900,540 S 1500,360 2100,600" Stroke="{StaticResource WaveGrad}" StrokeThickness="14" Opacity="0.12"/>
        <Path Data="M -200,560 C 200,380 520,760 900,540 S 1500,360 2100,600" Stroke="{StaticResource WaveGrad}" StrokeThickness="2.5" Opacity="0.7"/>
        <Path Data="M -200,140 C 300,40 700,260 1100,120 S 1700,60 2100,180" Stroke="{StaticResource WaveGrad}" StrokeThickness="10" Opacity="0.08"/>
        <Path Data="M -200,140 C 300,40 700,260 1100,120 S 1700,60 2100,180" Stroke="{StaticResource WaveGrad}" StrokeThickness="2" Opacity="0.45"/>
      </Canvas>
    </Canvas>

    <!-- MENU LATERAL -->
    <Border Background="#CC140E26" BorderBrush="#2C2350" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="24,20,16,18">
          <StackPanel Orientation="Horizontal">
            <Grid>
              <TextBlock x:Name="logoGlitchA" Text="OPTIMIZER" FontWeight="Black" FontSize="25" Foreground="#22D3EE" Opacity="0">
                <TextBlock.RenderTransform><TranslateTransform X="0"/></TextBlock.RenderTransform>
              </TextBlock>
              <TextBlock x:Name="logoGlitchB" Text="OPTIMIZER" FontWeight="Black" FontSize="25" Foreground="#FF2E88" Opacity="0">
                <TextBlock.RenderTransform><TranslateTransform X="0"/></TextBlock.RenderTransform>
              </TextBlock>
              <TextBlock x:Name="logoMain" Text="OPTIMIZER" FontWeight="Black" FontSize="25">
                <TextBlock.RenderTransform><TranslateTransform X="0"/></TextBlock.RenderTransform>
              </TextBlock>
            </Grid>
            <Border x:Name="logoBadge" CornerRadius="2" Background="{StaticResource PurpleGrad}" Margin="7,3,0,3" Padding="7,0" VerticalAlignment="Stretch">
              <Border.Effect>
                <DropShadowEffect Color="#D946EF" BlurRadius="12" ShadowDepth="0" Opacity="0.9"/>
              </Border.Effect>
              <TextBlock Text="GBZ" FontWeight="Black" FontSize="16" VerticalAlignment="Center"/>
            </Border>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="1,4,0,0">
            <TextBlock Text="&gt; by " FontFamily="Consolas" Foreground="#9D93C4" FontSize="11.5"/>
            <TextBlock Text="n0ctlow" FontFamily="Consolas" Foreground="#E879F9" FontSize="11.5" FontWeight="Bold"/>
            <TextBlock Text="  [ONLINE]" FontFamily="Consolas" Foreground="#39FF88" FontSize="11.5"/>
            <TextBlock x:Name="txtVersion" Text="" FontFamily="Consolas" Foreground="#6B6390" FontSize="11.5"/>
          </StackPanel>
        </StackPanel>

        <Border DockPanel.Dock="Bottom" Margin="16,0,16,16" CornerRadius="4" Padding="16,12" Background="{StaticResource HeroGrad}">
          <StackPanel>
            <TextBlock Text="MODO GAMER" FontSize="11" FontWeight="Bold" Foreground="#F5D0FE"/>
            <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
              <Ellipse x:Name="dotGamer" Width="10" Height="10" Fill="#4A3F70" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock x:Name="txtGamerSide" Text="DESLIGADO" FontWeight="Black" FontSize="16" Foreground="White"/>
            </StackPanel>
            <TextBlock Text="Ative no Painel antes de jogar" FontSize="11" Foreground="#F5D0FE" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>

        <CheckBox x:Name="chkAmbient" DockPanel.Dock="Bottom" Style="{StaticResource Switch}" Margin="16,0,16,10">
          <StackPanel>
            <TextBlock Text="Animações extras" FontSize="13" FontWeight="SemiBold"/>
            <TextBlock Text="Partículas, scan e fundo animado. Desligue se pesar." FontSize="10" Foreground="#9D93C4" TextWrapping="Wrap"/>
          </StackPanel>
        </CheckBox>

        <ScrollViewer VerticalScrollBarVisibility="Auto">
        <Grid x:Name="navHost">
        <StackPanel>
          <TextBlock Text="// MENU" Style="{StaticResource Label}" Margin="30,0,0,8"/>
          <Button x:Name="navDash" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80F;" Style="{StaticResource Icon}"/><TextBlock Text="Painel"/></StackPanel></Button>
          <Button x:Name="navGamer" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7FC;" Style="{StaticResource Icon}"/><TextBlock Text="Modo Gamer"/></StackPanel></Button>
          <Button x:Name="navNet" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE774;" Style="{StaticResource Icon}"/><TextBlock Text="Internet e lag"/></StackPanel></Button>
          <Button x:Name="navLink" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8D6;" Style="{StaticResource Icon}"/><TextBlock Text="Música"/></StackPanel></Button>
          <Button x:Name="navColor" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7F4;" Style="{StaticResource Icon}"/><TextBlock Text="Tela e cores"/></StackPanel></Button>
          <Button x:Name="navRgb" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xEA80;" Style="{StaticResource Icon}"/><TextBlock Text="Iluminação RGB"/></StackPanel></Button>
          <Button x:Name="navMem" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE9D9;" Style="{StaticResource Icon}"/><TextBlock Text="Memória e processos"/></StackPanel></Button>
          <Button x:Name="navClean" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" Style="{StaticResource Icon}"/><TextBlock Text="Limpeza"/></StackPanel></Button>
          <TextBlock Text="// SISTEMA" Style="{StaticResource Label}" Margin="30,16,0,8"/>
          <Button x:Name="navPerf" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE713;" Style="{StaticResource Icon}"/><TextBlock Text="Ajustes do Windows"/></StackPanel></Button>
          <Button x:Name="navStart" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7E8;" Style="{StaticResource Icon}"/><TextBlock Text="Inicialização"/></StackPanel></Button>
          <Button x:Name="navMaint" Style="{StaticResource Nav}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE90F;" Style="{StaticResource Icon}"/><TextBlock Text="Manutenção"/></StackPanel></Button>
        </StackPanel>
        <Border x:Name="navIndicator" Width="4" Height="28" CornerRadius="1" Background="{StaticResource PurpleGrad}" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="6,0,0,0" Opacity="0">
          <Border.Effect><DropShadowEffect Color="#E879F9" BlurRadius="10" ShadowDepth="0" Opacity="0.9"/></Border.Effect>
          <Border.RenderTransform><TranslateTransform Y="0"/></Border.RenderTransform>
        </Border>
        </Grid>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- CONTEÚDO -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="52"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="120"/>
      </Grid.RowDefinitions>

      <!-- Barra superior -->
      <Grid Margin="28,10,8,0">
        <Border HorizontalAlignment="Left" VerticalAlignment="Center" Background="#B31C1533" BorderBrush="#2C2350" BorderThickness="1" CornerRadius="3" Padding="14,7">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&gt; bem-vindo de volta, " Foreground="#9D93C4" FontSize="12.5" FontFamily="Consolas"/>
            <TextBlock x:Name="txtUserNick" Text="player" FontWeight="Bold" FontSize="12.5" FontFamily="Consolas" Foreground="#E879F9"/>
            <Button x:Name="btnChangeNick" Style="{StaticResource ChromeIcon}" Content="&#xE70F;" Margin="6,-4,-6,-4" ToolTip="Trocar nick"/>
          </StackPanel>
        </Border>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border x:Name="npPill" Background="#B31C1533" BorderBrush="#2C2350" BorderThickness="1" CornerRadius="3" Padding="10,2,4,2" Margin="0,0,12,0" VerticalAlignment="Center" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE8D6;" FontFamily="Segoe MDL2 Assets" Foreground="#39FF88" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock x:Name="txtNpTop" Text="" FontSize="12" MaxWidth="240" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
              <Button x:Name="btnNpTopPlay" Style="{StaticResource ChromeIcon}" Content="&#xE769;" Margin="6,0,0,0"/>
              <Button x:Name="btnNpTopNext" Style="{StaticResource ChromeIcon}" Content="&#xE893;"/>
            </StackPanel>
          </Border>
          <Border Background="#B31C1533" BorderBrush="#2C2350" BorderThickness="1" CornerRadius="3" Padding="12,6" Margin="0,0,12,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="dotPingChip" Width="8" Height="8" Fill="#39FF88" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock Text="Ping " Foreground="#9D93C4" FontSize="12"/>
              <TextBlock x:Name="txtPingChip" Text="--" FontWeight="Bold" FontSize="12"/>
            </StackPanel>
          </Border>
          <Button x:Name="btnMin" Style="{StaticResource WinBtn}" Content="&#xE921;"/>
          <Button x:Name="btnMax" Style="{StaticResource WinBtn}" Content="&#xE922;"/>
          <Button x:Name="btnClose" Style="{StaticResource WinClose}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="28,14,28,16">
        <StackPanel>
          <TextBlock x:Name="txtPageTitle" Text="PAINEL" FontSize="30" FontWeight="Black"/>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
            <TextBlock x:Name="txtPageSub" Text="" Foreground="#B9B0DA" FontFamily="Consolas" FontSize="12.5"/>
            <TextBlock Text="&#x2588;" Foreground="#E879F9" FontFamily="Consolas" FontSize="12.5" Margin="2,0,0,0">
              <TextBlock.Triggers>
                <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                  <BeginStoryboard>
                    <Storyboard RepeatBehavior="Forever">
                      <DoubleAnimationUsingKeyFrames Storyboard.TargetProperty="Opacity">
                        <DiscreteDoubleKeyFrame KeyTime="0:0:0" Value="1"/>
                        <DiscreteDoubleKeyFrame KeyTime="0:0:0.5" Value="0"/>
                        <DiscreteDoubleKeyFrame KeyTime="0:0:1" Value="1"/>
                      </DoubleAnimationUsingKeyFrames>
                    </Storyboard>
                  </BeginStoryboard>
                </EventTrigger>
              </TextBlock.Triggers>
            </TextBlock>
          </StackPanel>
        </StackPanel>
        <Border HorizontalAlignment="Right" VerticalAlignment="Center" Background="#B31C1533" BorderBrush="#2C2350" BorderThickness="1" CornerRadius="3" Padding="12,7">
          <StackPanel Orientation="Horizontal">
            <Grid Width="14" Height="14" Margin="0,0,8,0" VerticalAlignment="Center">
              <Ellipse x:Name="dotStatus" Width="9" Height="9" Fill="#39FF88"/>
              <Ellipse x:Name="spinStatus" Stroke="#E879F9" StrokeThickness="2.5" StrokeDashArray="3 2" Visibility="Collapsed" RenderTransformOrigin="0.5,0.5"/>
            </Grid>
            <TextBlock x:Name="txtStatus" Text="Pronto" FontSize="12"/>
          </StackPanel>
        </Border>
      </Grid>

      <Grid Grid.Row="2" Margin="28,0,12,0">

        <!-- ===== PAINEL ===== -->
        <ScrollViewer x:Name="pgDash" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <StackPanel>
            <!-- Banner -->
            <Border Style="{StaticResource Hero}" Height="220">
              <Grid>
                <Ellipse Width="230" Height="230" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,30,0" Fill="#1AFFFFFF"/>
                <Ellipse Width="150" Height="150" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,70,0" Fill="#14FFFFFF"/>
                <TextBlock x:Name="heroPad" Text="&#xE7FC;" FontFamily="Segoe MDL2 Assets" FontSize="130" Foreground="#E6FFFFFF" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,60,0">
                  <TextBlock.RenderTransform>
                    <TranslateTransform Y="0"/>
                  </TextBlock.RenderTransform>
                </TextBlock>
                <Ellipse x:Name="star1" Width="8" Height="8" Fill="White" Opacity="0.7" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,20,300,0">
                </Ellipse>
                <Ellipse x:Name="star2" Width="5" Height="5" Fill="White" Opacity="0.6" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,260,30">
                </Ellipse>
                <Ellipse x:Name="star3" Width="6" Height="6" Fill="#39FF88" Opacity="0.8" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,40,24,0">
                </Ellipse>
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Left" MaxWidth="560">
                  <StackPanel Orientation="Horizontal">
                    <Border x:Name="badgeGamer" CornerRadius="2" Padding="10,3" Background="#40FFFFFF">
                      <TextBlock x:Name="txtGamerState" Text="DESLIGADO" FontSize="11" FontWeight="Black"/>
                    </Border>
                    <TextBlock x:Name="txtHeroGreet" Text="Pronto para jogar?" Margin="10,0,0,0" Foreground="#F5D0FE" FontSize="13" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock x:Name="txtHeroTitle" Text="Ative o Modo Gamer" FontSize="34" FontWeight="Black" Margin="0,8,0,4"/>
                  <TextBlock Text="Energia no máximo, RAM livre, DNS limpo e downloads do Windows pausados até reiniciar." Foreground="#F5D0FE" FontSize="13" TextWrapping="Wrap"/>
                  <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                    <Button x:Name="btnGamerOn" Style="{StaticResource PlayBtn}"/>
                    <StackPanel VerticalAlignment="Center" Margin="14,0,22,0">
                      <TextBlock Text="ATIVAR" FontWeight="Black" FontSize="16"/>
                      <TextBlock Text="um clique" Foreground="#F5D0FE" FontSize="11"/>
                    </StackPanel>
                    <Button x:Name="btnGamerOff" Style="{StaticResource Glass}" Content="Voltar ao normal" VerticalAlignment="Center" Margin="0"/>
                  </StackPanel>
                </StackPanel>
              </Grid>
            </Border>

            <!-- Medidores -->
            <UniformGrid Columns="4">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock Text="// PROCESSADOR" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                    <Border Style="{StaticResource Chip}" HorizontalAlignment="Right"><TextBlock Text="CPU" FontSize="10" FontWeight="Bold" Foreground="#E879F9"/></Border>
                  </DockPanel>
                  <Grid Width="118" Height="118" Margin="0,14,0,4">
                    <Ellipse x:Name="gRing1" Margin="-9" Stroke="#5B45A8" StrokeThickness="2" StrokeDashArray="1 4" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="0"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <Ellipse Stroke="#2A2148" StrokeThickness="11"/>
                    <Ellipse x:Name="gCpu" Stroke="{StaticResource GaugeGrad}" StrokeThickness="11" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock x:Name="txtCpu" Text="--" Style="{StaticResource GaugeNum}"/>
                      <TextBlock Text="em uso" Style="{StaticResource GaugeSub}"/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock Text="// MEMÓRIA" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                    <Border Style="{StaticResource Chip}" HorizontalAlignment="Right"><TextBlock Text="RAM" FontSize="10" FontWeight="Bold" Foreground="#E879F9"/></Border>
                  </DockPanel>
                  <Grid Width="118" Height="118" Margin="0,14,0,4">
                    <Ellipse x:Name="gRing2" Margin="-9" Stroke="#5B45A8" StrokeThickness="2" StrokeDashArray="1 4" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="0"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <Ellipse Stroke="#2A2148" StrokeThickness="11"/>
                    <Ellipse x:Name="gRam" Stroke="{StaticResource GaugeGrad}" StrokeThickness="11" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock x:Name="txtRam" Text="--" Style="{StaticResource GaugeNum}"/>
                      <TextBlock x:Name="txtRamSub" Text="" Style="{StaticResource GaugeSub}"/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock x:Name="txtDiskLabel" Text="DISCO" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                    <Border Style="{StaticResource Chip}" HorizontalAlignment="Right"><TextBlock Text="SSD/HD" FontSize="10" FontWeight="Bold" Foreground="#E879F9"/></Border>
                  </DockPanel>
                  <Grid Width="118" Height="118" Margin="0,14,0,4">
                    <Ellipse x:Name="gRing3" Margin="-9" Stroke="#5B45A8" StrokeThickness="2" StrokeDashArray="1 4" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="0"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <Ellipse Stroke="#2A2148" StrokeThickness="11"/>
                    <Ellipse x:Name="gDisk" Stroke="{StaticResource GaugeGrad}" StrokeThickness="11" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock x:Name="txtDisk" Text="--" Style="{StaticResource GaugeNum}"/>
                      <TextBlock x:Name="txtDiskSub" Text="" Style="{StaticResource GaugeSub}"/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock Text="// PING" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                    <Border Style="{StaticResource Chip}" HorizontalAlignment="Right" Background="#1A39FF88"><TextBlock Text="LIVE" FontSize="10" FontWeight="Bold" Foreground="#39FF88"/></Border>
                  </DockPanel>
                  <Grid Width="118" Height="118" Margin="0,14,0,4">
                    <Ellipse x:Name="gRing4" Margin="-9" Stroke="#5B45A8" StrokeThickness="2" StrokeDashArray="1 4" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="0"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <Ellipse Stroke="#2A2148" StrokeThickness="11"/>
                    <Ellipse x:Name="gPing" Stroke="{StaticResource GreenGrad}" StrokeThickness="11" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock x:Name="txtPing" Text="--" Style="{StaticResource GaugeNum}" FontSize="20"/>
                      <TextBlock Text="até 1.1.1.1" Style="{StaticResource GaugeSub}"/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Border>
            </UniformGrid>

            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="3*"/>
                <ColumnDefinition Width="2*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock Text="// ATIVIDADE DA CPU AO VIVO" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtCpuSpark" Text="--" HorizontalAlignment="Right" FontWeight="Black" FontSize="18" Foreground="#39FF88"/>
                  </DockPanel>
                  <Grid x:Name="sparkHost" Height="110" Margin="0,12,0,0" ClipToBounds="True">
                    <Polygon x:Name="sparkCpuArea" Fill="{StaticResource GreenFade}"/>
                    <Polyline x:Name="sparkCpu" Stroke="#39FF88" StrokeThickness="2.5" StrokeLineJoin="Round">
                    </Polyline>
                  </Grid>
                  <DockPanel Margin="0,14,0,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="// LIGADO HÁ  " Style="{StaticResource Label}" VerticalAlignment="Center"/>
                      <TextBlock x:Name="txtUptime" Text="--" FontWeight="Black" FontSize="15"/>
                    </StackPanel>
                    <TextBlock x:Name="txtUptimeSub" Text="" HorizontalAlignment="Right" Foreground="#9D93C4" FontSize="12" VerticalAlignment="Center"/>
                  </DockPanel>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// AÇÕES RÁPIDAS" Style="{StaticResource Label}" Margin="0,0,0,12"/>
                  <Button x:Name="btnQuick" Style="{StaticResource Primary}" Margin="0,0,0,8" Content="Otimização rápida"/>
                  <Button x:Name="btnQuickDiag" Margin="0,0,0,8" Content="Escanear travadinhas"/>
                  <Button x:Name="btnQuickPing" Margin="0,0,0,8" Content="Testar lag da internet"/>
                  <Button x:Name="btnQuickRestore" Margin="0" Content="Criar ponto de restauração"/>
                </StackPanel>
              </Border>
            </Grid>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// SEU SETUP" Style="{StaticResource Label}"/>
                <TextBlock x:Name="txtSysInfo" Text="Carregando..." TextWrapping="Wrap" LineHeight="24" Margin="0,10,0,0" FontSize="13" Foreground="#E9E4FF"/>
              </StackPanel>
            </Border>
          </StackPanel></AdornerDecorator>

        </ScrollViewer>

        <!-- ===== MODO GAMER ===== -->
        <ScrollViewer x:Name="pgGamer" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <StackPanel>
            <Border Style="{StaticResource Hero}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid Width="140" Height="140" Margin="0,0,26,0">
                  <Ellipse x:Name="gRing5" Margin="-10" Stroke="#66FFFFFF" StrokeThickness="2" StrokeDashArray="1 4" RenderTransformOrigin="0.5,0.5">
                    <Ellipse.RenderTransform><RotateTransform Angle="0"/></Ellipse.RenderTransform>
                  </Ellipse>
                  <Ellipse Stroke="#33FFFFFF" StrokeThickness="13"/>
                  <Ellipse x:Name="gScore" Stroke="White" StrokeThickness="13" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                    <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                  </Ellipse>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="txtScore" Text="--" FontSize="34" FontWeight="Black" HorizontalAlignment="Center"/>
                    <TextBlock Text="de 100" FontSize="11" Foreground="#F5D0FE" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Grid>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                  <Border Style="{StaticResource Chip}" Background="#33FFFFFF" HorizontalAlignment="Left"><TextBlock Text="DIAGNÓSTICO" FontSize="10" FontWeight="Black"/></Border>
                  <TextBlock Text="Caçador de travadinhas" FontSize="28" FontWeight="Black" Margin="0,8,0,4"/>
                  <TextBlock x:Name="txtScoreSub" Foreground="#F5D0FE" FontSize="13" TextWrapping="Wrap" Text="Escaneia o PC atrás das causas mais comuns de travadas, lag e queda de FPS, e diz o que resolver."/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
                  <Button x:Name="btnDiag" Style="{StaticResource PlayBtn}"/>
                  <StackPanel VerticalAlignment="Center" Margin="14,0,6,0">
                    <TextBlock Text="ESCANEAR" FontWeight="Black" FontSize="16"/>
                    <TextBlock Text="leva uns 5 segundos" Foreground="#F5D0FE" FontSize="11"/>
                  </StackPanel>
                </StackPanel>
              </Grid>
            </Border>
            <Border x:Name="cardDiag" Style="{StaticResource Card}" Visibility="Collapsed">
              <StackPanel>
                <TextBlock Text="// RESULTADO DO ESCANEAMENTO" Style="{StaticResource Label}"/>
                <StackPanel x:Name="spDiag" Margin="0,12,0,0"/>
              </StackPanel>
            </Border>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock Text="// MENOS INPUT LAG" Style="{StaticResource Label}" Foreground="#E879F9" VerticalAlignment="Center"/>
                    <Border Style="{StaticResource Chip}" HorizontalAlignment="Right"><TextBlock Text="MOUSE + TECLADO" FontSize="10" FontWeight="Bold"/></Border>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Desc}" Text="Deixa mouse e teclado respondendo mais rápido e direto."/>
                  <StackPanel x:Name="spInput"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock Text="// MENOS TRAVADINHAS, MAIS FPS" Style="{StaticResource Label}" Foreground="#E879F9" VerticalAlignment="Center"/>
                    <Border Style="{StaticResource Chip}" HorizontalAlignment="Right"><TextBlock Text="FPS" FontSize="10" FontWeight="Bold"/></Border>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Desc}" Text="Faz o Windows priorizar o jogo e tira o que rouba desempenho escondido."/>
                  <StackPanel x:Name="spStutter"/>
                </StackPanel>
              </Border>
            </Grid>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// INPUT LAG: O QUE NENHUM PROGRAMA FAZ POR VOCÊ" Style="{StaticResource Label}"/>
                <TextBlock TextWrapping="Wrap" LineHeight="23" Margin="0,10,0,12" Foreground="#E9E4FF" FontSize="13"
                           Text="• Confira se o monitor está na taxa máxima (ex: 144 Hz). Muita gente compra monitor rápido e ele fica em 60 Hz!&#x0a;• Jogue em tela cheia e desligue o V-Sync. Para não ter tearing, limite o FPS um pouco abaixo da taxa do monitor.&#x0a;• Se o jogo tiver NVIDIA Reflex ou AMD Anti-Lag, ligue: é o que mais reduz input lag.&#x0a;• Ligue o mouse direto na placa-mãe (atrás do PC), não em hub ou na frente do gabinete.&#x0a;• Mouse gamer: use taxa de 1000 Hz no programa do fabricante.&#x0a;• Atualize o driver da placa de vídeo pelo site da NVIDIA, AMD ou Intel."/>
                <Button x:Name="btnDisplay" HorizontalAlignment="Left" Content="Abrir configurações de tela (taxa de atualização)"/>
              </StackPanel>
            </Border>
          </StackPanel></AdornerDecorator>

        </ScrollViewer>

        <!-- ===== INTERNET ===== -->
        <ScrollViewer x:Name="pgNet" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <StackPanel>
            <UniformGrid Columns="4">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// CONEXÃO" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtConn" Text="--" Style="{StaticResource Big}"/>
                  <TextBlock x:Name="txtConnSub" Text="" Foreground="#9D93C4" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// PING AGORA" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtPing2" Text="--" Style="{StaticResource Big}"/>
                  <TextBlock Text="até 1.1.1.1 (Cloudflare)" Foreground="#9D93C4" FontSize="11" Margin="0,8,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// DOWNLOAD EM USO" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtDown" Text="--" Style="{StaticResource Big}" Foreground="#E879F9"/>
                  <TextBlock Text="o que o PC está baixando agora" Foreground="#9D93C4" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// UPLOAD EM USO" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtUp" Text="--" Style="{StaticResource Big}" Foreground="#A855F7"/>
                  <TextBlock Text="o que o PC está enviando agora" Foreground="#9D93C4" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </UniformGrid>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel>
                  <TextBlock Text="// TRÁFEGO AO VIVO (DOWNLOAD)" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="txtNetPeak" Text="" HorizontalAlignment="Right" Foreground="#9D93C4" FontSize="12"/>
                </DockPanel>
                <Grid x:Name="sparkNetHost" Height="90" Margin="0,12,0,0" ClipToBounds="True">
                  <Polygon x:Name="sparkNetArea" Fill="{StaticResource PinkFade}"/>
                  <Polyline x:Name="sparkNet" Stroke="#E879F9" StrokeThickness="2.5" StrokeLineJoin="Round">
                  </Polyline>
                </Grid>
              </StackPanel>
            </Border>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// TESTE DE LAG" Style="{StaticResource Label}" Foreground="#E879F9"/>
                  <TextBlock Style="{StaticResource Desc}" Text="Mede ping, jitter (oscilação) e perda de pacotes até o seu roteador e até a internet. Assim dá para saber se o lag é do seu Wi-Fi/rede ou do provedor."/>
                  <Button x:Name="btnPingTest" Style="{StaticResource Primary}" HorizontalAlignment="Left" Content="Testar ping, jitter e perda"/>
                  <StackPanel x:Name="spPing" Margin="0,6,0,0"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// DNS MAIS RÁPIDO" Style="{StaticResource Label}" Foreground="#E879F9"/>
                  <TextBlock Style="{StaticResource Desc}" Text="Compara o DNS do seu provedor com Cloudflare, Google, Quad9 e OpenDNS. Um DNS rápido acelera abrir sites, logins e matchmaking. Ele não muda o ping dentro da partida."/>
                  <WrapPanel>
                    <Button x:Name="btnDnsTest" Content="Testar DNS"/>
                    <Button x:Name="btnDnsBest" Style="{StaticResource Primary}" Content="Usar o mais rápido" IsEnabled="False"/>
                    <Button x:Name="btnDnsAuto" Content="DNS automático"/>
                  </WrapPanel>
                  <StackPanel x:Name="spDns" Margin="0,6,0,0"/>
                </StackPanel>
              </Border>
            </Grid>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// AJUSTES DE REDE PARA JOGOS" Style="{StaticResource Label}"/>
                <TextBlock Style="{StaticResource Desc}" Text="Reduzem atraso no envio de pacotes e oscilação. Os que mexem na placa de rede reiniciam ela: a internet cai por 2 ou 3 segundos."/>
                <StackPanel x:Name="spNetTweaks"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// FERRAMENTAS DE REDE" Style="{StaticResource Label}"/>
                <TextBlock Style="{StaticResource Desc}" Text="Use quando sites não abrem, a internet some do nada ou fica instável. Resetar a rede exige reiniciar o PC."/>
                <WrapPanel>
                  <Button x:Name="btnNetUsers" Content="Quem está usando a internet"/>
                  <Button x:Name="btnDns" Content="Limpar cache de DNS"/>
                  <Button x:Name="btnRenewIp" Content="Renovar IP"/>
                  <Button x:Name="btnNetReset" Style="{StaticResource Danger}" Content="Resetar configurações de rede"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel></AdornerDecorator>

        </ScrollViewer>

        <!-- ===== MÚSICA (o Discord fica guardado aqui, escondido, até ser liberado) ===== -->
        <ScrollViewer x:Name="pgLink" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <StackPanel>
            <Border x:Name="cardDiscord" Visibility="Collapsed">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <TextBlock Text="// DISCORD" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                    <Border Style="{StaticResource Chip}" HorizontalAlignment="Right">
                      <StackPanel Orientation="Horizontal">
                        <Ellipse x:Name="dcDot" Width="7" Height="7" Fill="#4A3F70" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBlock x:Name="txtDcStatus" Text="desligado" FontSize="10.5" FontWeight="Bold"/>
                      </StackPanel>
                    </Border>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Desc}" Text="Aparece no seu perfil do Discord que você está usando o Optimizer GBZ, com o que está fazendo no painel."/>
                  <Border Background="#232428" CornerRadius="6" Padding="14" Margin="0,0,0,14">
                    <StackPanel>
                      <TextBlock Text="JOGANDO" FontSize="10.5" FontWeight="Bold" Foreground="#B5BAC1" Margin="0,0,0,8"/>
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border Width="64" Height="64" CornerRadius="6" Background="{StaticResource HeroGrad}">
                          <TextBlock Text="GBZ" FontWeight="Black" FontSize="19" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
                          <TextBlock Text="Optimizer GBZ" FontWeight="Bold" FontSize="14" Foreground="#F2F3F5"/>
                          <TextBlock x:Name="txtDcPrevDetails" Text="Otimizando o PC" FontSize="12.5" Foreground="#DBDEE1"/>
                          <TextBlock x:Name="txtDcPrevState" Text="Na aba Painel" FontSize="12.5" Foreground="#DBDEE1"/>
                          <TextBlock x:Name="txtDcPrevTime" Text="00:00 decorrido" FontSize="12.5" Foreground="#DBDEE1"/>
                        </StackPanel>
                      </Grid>
                    </StackPanel>
                  </Border>
                  <CheckBox x:Name="chkDiscord" Style="{StaticResource Switch}">
                    <StackPanel>
                      <TextBlock Text="Mostrar no meu Discord" FontSize="13" FontWeight="SemiBold"/>
                      <TextBlock Text="O Discord precisa estar aberto no PC." FontSize="11" Foreground="#9D93C4"/>
                    </StackPanel>
                  </CheckBox>
                  <TextBlock Text="// ID DO APLICATIVO" Style="{StaticResource Label}" Margin="0,8,0,6"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="txtDiscordId" Background="#241B40" Foreground="White" BorderBrush="#3A2E66" Padding="8,7" FontFamily="Consolas" FontSize="13" CaretBrush="White" Margin="0,0,8,8"/>
                    <Button x:Name="btnDiscordSave" Grid.Column="1" Content="Salvar" Margin="0,0,0,8"/>
                  </Grid>
                  <Button x:Name="btnDiscordPortal" Style="{StaticResource Primary}" HorizontalAlignment="Left" Content="ABRIR PORTAL DO DISCORD"/>
                  <TextBlock Foreground="#B9B0DA" FontSize="12" TextWrapping="Wrap" LineHeight="20" Margin="0,8,0,0"
                             Text="Como configurar (só uma vez, uns 2 minutos):&#x0a;1. Clique em Abrir portal do Discord e entre com a sua conta.&#x0a;2. New Application. O nome que você der é o que aparece no perfil, então coloque Optimizer GBZ.&#x0a;3. Copie o Application ID, cole aqui em cima e clique em Salvar.&#x0a;4. Opcional: em Rich Presence > Art Assets, envie a imagem logo.png (fica na pasta assets do projeto) com o nome logo."/>
                </StackPanel>
              </Border>
            </Border>

            <!-- Player principal -->
            <Border x:Name="musicHero" Style="{StaticResource Hero}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid Width="290" Height="220">
                  <Grid x:Name="vinyl" Width="206" Height="206" HorizontalAlignment="Right" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform><RotateTransform Angle="0"/></Grid.RenderTransform>
                    <Ellipse Fill="#0B0912" Stroke="#33FFFFFF" StrokeThickness="1"/>
                    <Ellipse Margin="12" Stroke="#18FFFFFF" StrokeThickness="1"/>
                    <Ellipse Margin="22" Stroke="#14FFFFFF" StrokeThickness="1"/>
                    <Ellipse Margin="32" Stroke="#18FFFFFF" StrokeThickness="1"/>
                    <Ellipse Margin="42" Stroke="#12FFFFFF" StrokeThickness="1"/>
                    <Ellipse Margin="52" Stroke="#16FFFFFF" StrokeThickness="1"/>
                    <Ellipse>
                      <Ellipse.Fill>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                          <GradientStop Color="#00FFFFFF" Offset="0.3"/>
                          <GradientStop Color="#22FFFFFF" Offset="0.5"/>
                          <GradientStop Color="#00FFFFFF" Offset="0.7"/>
                        </LinearGradientBrush>
                      </Ellipse.Fill>
                    </Ellipse>
                    <Ellipse x:Name="vinylLabel" Width="72" Height="72" Fill="{StaticResource PurpleGrad}"/>
                    <TextBlock Text="GBZ" FontWeight="Black" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,26"/>
                    <Ellipse Width="9" Height="9" Fill="#0B0912"/>
                  </Grid>
                  <Border x:Name="musicArt" Width="196" Height="196" HorizontalAlignment="Left" VerticalAlignment="Center" CornerRadius="4" Background="{StaticResource HeroGrad}" BorderBrush="#55FFFFFF" BorderThickness="1">
                    <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="24" ShadowDepth="6" Opacity="0.6"/></Border.Effect>
                    <TextBlock x:Name="musicArtIcon" Text="&#xE8D6;" FontFamily="Segoe MDL2 Assets" FontSize="56" Foreground="#CCFFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                </Grid>
                <StackPanel Grid.Column="1" Margin="28,0,0,0" VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal">
                    <Border Style="{StaticResource Chip}" Background="#33000000"><TextBlock x:Name="txtMusicApp" Text="nenhum player" FontSize="10.5" FontWeight="Black"/></Border>
                    <Border x:Name="chipMusicState" Style="{StaticResource Chip}" Background="#33FFFFFF" Margin="8,0,0,0"><TextBlock x:Name="txtMusicState" Text="PARADO" FontSize="10.5" FontWeight="Black"/></Border>
                  </StackPanel>
                  <TextBlock x:Name="txtMusicTitle" Text="Nada tocando" FontWeight="Black" FontSize="30" TextWrapping="Wrap" MaxHeight="84" TextTrimming="CharacterEllipsis" Margin="0,10,0,2"/>
                  <TextBlock x:Name="txtMusicArtist" Text="Abra o Spotify e dê play" Foreground="#F5D0FE" FontSize="15" TextTrimming="CharacterEllipsis" Margin="0,0,0,14"/>
                  <ProgressBar x:Name="barMusic" Height="6"/>
                  <DockPanel Margin="0,5,0,0">
                    <TextBlock x:Name="txtMusicPos" Text="0:00" FontSize="11.5" Foreground="#F5D0FE" FontFamily="Consolas"/>
                    <TextBlock x:Name="txtMusicEnd" Text="0:00" FontSize="11.5" Foreground="#F5D0FE" FontFamily="Consolas" HorizontalAlignment="Right"/>
                  </DockPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                    <Button x:Name="btnMusicPrev" Style="{StaticResource RoundBtn}" Margin="0,0,6,0" Content="&#xE892;"/>
                    <Button x:Name="btnMusicPlay" Style="{StaticResource RoundBtn}" Width="60" Height="60" FontSize="21" Background="White" Foreground="#6D28D9" Content="&#xE768;"/>
                    <Button x:Name="btnMusicNext" Style="{StaticResource RoundBtn}" Content="&#xE893;"/>
                    <Button x:Name="btnOpenSpotify" Style="{StaticResource Glass}" Content="Abrir Spotify" VerticalAlignment="Center" Margin="14,0,0,0"/>
                  </StackPanel>
                </StackPanel>
                <Canvas x:Name="confetti" Grid.ColumnSpan="2" IsHitTestVisible="False"/>
              </Grid>
            </Border>

            <!-- Visualizador -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel>
                  <TextBlock Text="// VISUALIZADOR" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="txtMusicMood" Text="&gt; aguardando o play..." HorizontalAlignment="Right" FontFamily="Consolas" FontSize="12" Foreground="#E879F9"/>
                </DockPanel>
                <Grid Height="120" Margin="0,14,0,0" ClipToBounds="True">
                  <StackPanel x:Name="spViz" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Bottom"/>
                </Grid>
              </StackPanel>
            </Border>

            <!-- Estatísticas e brincadeiras -->
            <UniformGrid Columns="4">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// MÚSICAS NA SESSÃO" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtStatSongs" Text="0" Style="{StaticResource Big}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// TEMPO OUVINDO" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtStatTime" Text="0 min" Style="{StaticResource Big}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// ARTISTA DA SESSÃO" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtStatArtist" Text="--" Style="{StaticResource Big}" FontSize="19" TextTrimming="CharacterEllipsis" Margin="0,12,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// NÍVEL DE HYPE" Style="{StaticResource Label}"/>
                  <TextBlock x:Name="txtStatHype" Text="0%" Style="{StaticResource Big}" Foreground="#39FF88"/>
                </StackPanel>
              </Border>
            </UniformGrid>

            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// BRINCADEIRAS" Style="{StaticResource Label}"/>
                  <TextBlock Style="{StaticResource Desc}" Text="Liga e curte. Nada disso mexe no sistema."/>
                  <CheckBox x:Name="chkParty" Style="{StaticResource Switch}">
                    <StackPanel>
                      <TextBlock Text="Modo festa" FontSize="13" FontWeight="SemiBold"/>
                      <TextBlock Text="Visualizador arco-íris, borda piscando, vinil mais rápido e confete em toda música." FontSize="11" Foreground="#9D93C4" TextWrapping="Wrap"/>
                    </StackPanel>
                  </CheckBox>
                  <CheckBox x:Name="chkCoverTint" Style="{StaticResource Switch}">
                    <StackPanel>
                      <TextBlock Text="Cores da capa" FontSize="13" FontWeight="SemiBold"/>
                      <TextBlock Text="O player pega a cor da capa do álbum." FontSize="11" Foreground="#9D93C4" TextWrapping="Wrap"/>
                    </StackPanel>
                  </CheckBox>
                  <CheckBox x:Name="chkMusicRgb" Style="{StaticResource Switch}">
                    <StackPanel>
                      <TextBlock Text="LED do PC na cor da capa" FontSize="13" FontWeight="SemiBold"/>
                      <TextBlock Text="A cada música, o RGB do PC muda para a cor do álbum (precisa do OpenRGB)." FontSize="11" Foreground="#9D93C4" TextWrapping="Wrap"/>
                    </StackPanel>
                  </CheckBox>
                  <Button x:Name="btnConfetti" Style="{StaticResource Primary}" HorizontalAlignment="Left" Content="SOLTAR CONFETE"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// TERMINAL DA SESSÃO" Style="{StaticResource Label}"/>
                  <Border Background="#99000000" CornerRadius="3" Padding="12,10" Margin="0,10,0,0" MinHeight="190">
                    <TextBlock x:Name="txtMusicFeed" FontFamily="Consolas" FontSize="12" Foreground="#B9B0DA" LineHeight="20" TextWrapping="Wrap" Text="&gt; player online. dá o play aí."/>
                  </Border>
                </StackPanel>
              </Border>
            </Grid>
          </StackPanel>
</AdornerDecorator>
        </ScrollViewer>

        <!-- ===== TELA E CORES ===== -->
        <ScrollViewer x:Name="pgColor" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <StackPanel>
            <Border Style="{StaticResource Hero}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                  <Border Style="{StaticResource Chip}" Background="#33FFFFFF" HorizontalAlignment="Left"><TextBlock Text="MODO DE COR ATIVO" FontSize="10" FontWeight="Black"/></Border>
                  <TextBlock x:Name="txtColorProfile" Text="Padrão" FontSize="32" FontWeight="Black" Margin="0,8,0,4"/>
                  <TextBlock x:Name="txtColorDesc" Text="Cores originais do monitor." Foreground="#F5D0FE" FontSize="13" TextWrapping="Wrap" MaxWidth="440" HorizontalAlignment="Left"/>
                  <Button x:Name="btnColorReset" Style="{StaticResource Glass}" HorizontalAlignment="Left" Margin="0,16,0,0" Content="Restaurar cores originais"/>
                </StackPanel>
                <Border Grid.Column="1" Background="#33000000" CornerRadius="16" Padding="14" Margin="20,0,0,0" VerticalAlignment="Center">
                  <StackPanel Width="300">
                    <TextBlock Text="BARRAS DE TESTE" FontSize="10" FontWeight="Black" Foreground="#F5D0FE" Margin="0,0,0,8"/>
                    <UniformGrid Columns="7" Height="34"><Border Background="#FF0000" CornerRadius="6" Margin="0,0,4,0"/><Border Background="#00FF00" CornerRadius="6" Margin="0,0,4,0"/><Border Background="#0000FF" CornerRadius="6" Margin="0,0,4,0"/><Border Background="#FFFF00" CornerRadius="6" Margin="0,0,4,0"/><Border Background="#FF00FF" CornerRadius="6" Margin="0,0,4,0"/><Border Background="#00FFFF" CornerRadius="6" Margin="0,0,4,0"/><Border Background="#E0AC69" CornerRadius="6" Margin="0,0,0,0"/></UniformGrid>
                    <Border Height="18" CornerRadius="6" Margin="0,6,0,0">
                      <Border.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                          <GradientStop Color="#000000" Offset="0"/>
                          <GradientStop Color="#FFFFFF" Offset="1"/>
                        </LinearGradientBrush>
                      </Border.Background>
                    </Border>
                    <UniformGrid Columns="8" Height="24" Margin="0,6,0,0"><Border Background="#000000" CornerRadius="4" Margin="0,0,3,0"/><Border Background="#060606" CornerRadius="4" Margin="0,0,3,0"/><Border Background="#0C0C0C" CornerRadius="4" Margin="0,0,3,0"/><Border Background="#121212" CornerRadius="4" Margin="0,0,3,0"/><Border Background="#181818" CornerRadius="4" Margin="0,0,3,0"/><Border Background="#1E1E1E" CornerRadius="4" Margin="0,0,3,0"/><Border Background="#242424" CornerRadius="4" Margin="0,0,3,0"/><Border Background="#2A2A2A" CornerRadius="4" Margin="0,0,0,0"/></UniformGrid>
                    <TextBlock Text="Consegue ver os 8 quadrados escuros separados? Então dá para enxergar inimigos na sombra." FontSize="10" Foreground="#F5D0FE" TextWrapping="Wrap" Margin="0,6,0,0"/>
                  </StackPanel>
                </Border>
              </Grid>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// MODOS PRONTOS" Style="{StaticResource Label}"/>
                <TextBlock Style="{StaticResource Desc}" Text="Um clique muda a tela inteira, com transição suave."/>
                <UniformGrid x:Name="ugProfiles" Columns="3"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// AJUSTE FINO" Style="{StaticResource Label}"/>
                <TextBlock Style="{StaticResource Desc}" Text="Arraste à vontade: a tela muda na hora e o ajuste fica salvo."/>
                <StackPanel x:Name="spSliders" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// VIBRAÇÃO DIGITAL PELA PLACA DE VÍDEO" Style="{StaticResource Label}" Foreground="#E879F9"/>
                <TextBlock Style="{StaticResource Desc}" Text="A Vibração digital da NVIDIA e a Saturação da AMD são feitas pela própria placa: não pesam nada e funcionam até em jogo de tela cheia exclusiva. Para jogos competitivos, use elas para a saturação e este painel para brilho, gama e temperatura."/>
                <WrapPanel x:Name="wpGpuApps"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// BOM SABER" Style="{StaticResource Label}"/>
                <TextBlock TextWrapping="Wrap" LineHeight="22" Margin="0,8,0,0" Foreground="#E9E4FF" FontSize="12.5" Text="• Brilho, contraste, gama e temperatura ficam até reiniciar o PC. Quando você abre o painel, ele reaplica seu modo salvo.&#x0a;• A saturação só fica ativa enquanto o painel está aberto (pode deixar minimizado).&#x0a;• Jogos em tela cheia exclusiva ignoram a saturação do painel. Use tela cheia sem bordas ou a vibração digital da placa.&#x0a;• Com HDR ou Luz noturna do Windows ligados, os ajustes de cor podem não funcionar. Desligue-os para usar este modo."/>
              </StackPanel>
            </Border>
          </StackPanel></AdornerDecorator>

        </ScrollViewer>

        <!-- ===== ILUMINAÇÃO RGB ===== -->
        <ScrollViewer x:Name="pgRgb" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <StackPanel>
            <Border Style="{StaticResource Hero}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                  <Border Style="{StaticResource Chip}" Background="#33FFFFFF" HorizontalAlignment="Left"><TextBlock Text="CONTROLE UNIVERSAL DE LED" FontSize="10" FontWeight="Black"/></Border>
                  <TextBlock x:Name="txtRgbStatus" Text="Procurando OpenRGB..." FontSize="28" FontWeight="Black" Margin="0,8,0,4"/>
                  <TextBlock x:Name="txtRgbStatusSub" Foreground="#F5D0FE" FontSize="12.5" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Left" Text=""/>
                  <WrapPanel Margin="0,14,0,0">
                    <Button x:Name="btnRgbInstall" Style="{StaticResource Glass}" Background="White" Foreground="#6D28D9" FontWeight="Black" Content="INSTALAR OPENRGB"/>
                    <Button x:Name="btnRgbSite" Style="{StaticResource Glass}" Content="Versão mais nova (site oficial)"/>
                    <Button x:Name="btnRgbPawn" Style="{StaticResource Glass}" Content="Baixar PawnIO (RAM e placa-mãe)"/>
                    <Button x:Name="btnRgbBrowse" Style="{StaticResource Glass}" Content="Já tenho: procurar OpenRGB.exe"/>
                    <Button x:Name="btnRgbOpen" Style="{StaticResource Glass}" Content="Abrir OpenRGB"/>
                    <Button x:Name="btnRgbServer" Style="{StaticResource Glass}" Content="Deixar rodando (comandos rápidos)"/>
                  </WrapPanel>
                </StackPanel>
                <Grid Grid.Column="1" Width="160" Height="160" Margin="20,0,0,0">
                  <Ellipse x:Name="rgbPreviewGlow" Width="160" Height="160"/>
                  <Ellipse x:Name="rgbPreview" Width="88" Height="88" Fill="#A855F7" Stroke="White" StrokeThickness="3"/>
                  <TextBlock Text="&#xEA80;" FontFamily="Segoe MDL2 Assets" FontSize="34" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
              </Grid>
            </Border>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="3*"/>
                <ColumnDefinition Width="2*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// COR" Style="{StaticResource Label}"/>
                  <WrapPanel x:Name="wpRgbSwatches" Margin="0,12,0,6"/>
                  <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="120"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="Qualquer cor" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Slider x:Name="sldHue" Grid.Column="1" Style="{StaticResource HueSlider}" Minimum="0" Maximum="360" Value="270"/>
                  </Grid>
                  <Grid Margin="0,12,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="120"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="Código da cor" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <TextBox x:Name="txtRgbHex" Grid.Column="1" Width="120" Text="A855F7" Background="#241B40" Foreground="White" BorderBrush="#3A2E66" Padding="8,6" FontFamily="Consolas" FontSize="14" CaretBrush="White" MaxLength="7"/>
                  </Grid>
                  <TextBlock Text="// EFEITO" Style="{StaticResource Label}" Margin="0,18,0,8"/>
                  <WrapPanel x:Name="wpRgbModes"/>
                  <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="120"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="60"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="Brilho" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Slider x:Name="sldRgbBright" Grid.Column="1" Style="{StaticResource NeonSlider}" Minimum="0" Maximum="100" Value="100"/>
                    <TextBlock x:Name="txtRgbBright" Grid.Column="2" Text="100%" FontWeight="Black" Foreground="#E879F9" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                  </Grid>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="// APLICAR" Style="{StaticResource Label}"/>
                  <TextBlock Style="{StaticResource Desc}" Text="Aplica nos dispositivos marcados lá embaixo. Se nenhum estiver marcado, aplica em todos."/>
                  <StackPanel Orientation="Horizontal" Margin="0,4,0,16">
                    <Button x:Name="btnRgbApply" Style="{StaticResource PlayBtn}"/>
                    <StackPanel VerticalAlignment="Center" Margin="14,0,0,0">
                      <TextBlock Text="APLICAR NO PC" FontWeight="Black" FontSize="16"/>
                      <TextBlock x:Name="txtRgbBusy" Text="pronto" FontSize="11" Foreground="#9D93C4"/>
                    </StackPanel>
                  </StackPanel>
                  <CheckBox x:Name="chkRgbGamer" Style="{StaticResource Switch}">
                    <StackPanel>
                      <TextBlock Text="Mudar o LED ao ativar o Modo Gamer" FontSize="13" FontWeight="SemiBold" TextWrapping="Wrap"/>
                      <TextBlock Text="Usa a cor e o efeito escolhidos aqui." FontSize="11" Foreground="#9D93C4" TextWrapping="Wrap"/>
                    </StackPanel>
                  </CheckBox>
                </StackPanel>
              </Border>
            </Grid>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// CENAS PRONTAS" Style="{StaticResource Label}"/>
                <TextBlock Style="{StaticResource Desc}" Text="Um clique escolhe e já aplica."/>
                <UniformGrid x:Name="ugRgbScenes" Columns="4"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel>
                  <TextBlock Text="// DISPOSITIVOS ENCONTRADOS" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                  <Button x:Name="btnRgbScan" HorizontalAlignment="Right" Content="Procurar dispositivos" Margin="0"/>
                </DockPanel>
                <TextBlock x:Name="txtRgbDevHint" Style="{StaticResource Desc}" Text="Clique em Procurar dispositivos. A busca pode levar até 30 segundos."/>
                <StackPanel x:Name="spRgbDevices"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// BOM SABER" Style="{StaticResource Label}"/>
                <TextBlock TextWrapping="Wrap" LineHeight="22" Margin="0,8,0,0" Foreground="#E9E4FF" FontSize="12.5" Text="• O OpenRGB é gratuito e de código aberto, e controla milhares de peças de várias marcas: placa-mãe, memória RAM, placa de vídeo, fans, coolers, teclados e mouses. Confira as suas na lista em openrgb.org/devices.&#x0a;• Feche os programas da marca antes (Armoury Crate, iCUE, Mystic Light, RGB Fusion, Polychrome, SignalRGB...). Dois programas mandando no LED ao mesmo tempo dá conflito.&#x0a;• Para controlar memórias RAM e algumas placas-mãe, o OpenRGB precisa do PawnIO instalado.&#x0a;• Fans ligadas num controlador com controle remoto, sem cabo USB até a placa-mãe, não podem ser controladas por nenhum programa.&#x0a;• Nem toda peça tem todos os efeitos. Se um efeito não pegar numa peça, use Estático."/>
              </StackPanel>
            </Border>
          </StackPanel></AdornerDecorator>

        </ScrollViewer>

        <!-- ===== MEMÓRIA ===== -->
        <Grid x:Name="pgMem" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Style="{StaticResource Hero}">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock x:Name="txtMemDetail" Text="--" FontSize="20" FontWeight="Black"/>
                <ProgressBar x:Name="barMem2" Margin="0,12,0,12"/>
                <TextBlock Foreground="#F5D0FE" FontSize="12" TextWrapping="Wrap" Text="Liberar RAM esvazia a memória ociosa dos programas e a lista de espera do Windows. O ganho é imediato, mas temporário: o Windows volta a usar a RAM livre como cache, e isso é normal. Ajuda mais logo antes de abrir um jogo."/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0">
                <Button x:Name="btnFreeRam" Style="{StaticResource PlayBtn}"/>
                <StackPanel VerticalAlignment="Center" Margin="14,0,6,0">
                  <TextBlock Text="LIBERAR RAM" FontWeight="Black" FontSize="16"/>
                  <TextBlock Text="agora" Foreground="#F5D0FE" FontSize="11"/>
                </StackPanel>
              </StackPanel>
            </Grid>
          </Border>
          <Border Grid.Row="1" Style="{StaticResource Card}">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,12">
                <TextBlock Text="// PROGRAMAS QUE MAIS USAM MEMÓRIA" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button x:Name="btnProcRefresh" Content="Atualizar lista" Margin="0,0,8,0"/>
                  <Button x:Name="btnProcKill" Style="{StaticResource Danger}" Content="Finalizar selecionado" Margin="0"/>
                </StackPanel>
              </DockPanel>
              <DataGrid x:Name="gridProc">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Programa" Binding="{Binding Nome}" Width="*"/>
                  <DataGridTextColumn Header="PID" Binding="{Binding PID}" Width="90"/>
                  <DataGridTextColumn Header="Memória (MB)" Binding="{Binding RamMB}" Width="130"/>
                  <DataGridTextColumn Header="Tempo de CPU (s)" Binding="{Binding CpuSeg}" Width="140"/>
                </DataGrid.Columns>
              </DataGrid>
            </DockPanel>
          </Border>
        </Grid>

        <!-- ===== LIMPEZA ===== -->
        <Grid x:Name="pgClean" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Style="{StaticResource Hero}">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="txtCleanTotal" Text="Clique em Analisar para ver quanto espaço dá para liberar." FontSize="20" FontWeight="Black" TextWrapping="Wrap"/>
                <TextBlock x:Name="txtCleanDisk" Text="" Foreground="#F5D0FE" FontSize="12" Margin="0,6,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="btnAnalyze" Style="{StaticResource Glass}" Content="Analisar" Padding="20,12" Margin="0,0,10,0"/>
                <Button x:Name="btnClean" Style="{StaticResource PlayBtn}"/>
                <StackPanel VerticalAlignment="Center" Margin="14,0,6,0">
                  <TextBlock Text="LIMPAR" FontWeight="Black" FontSize="16"/>
                  <TextBlock Text="itens marcados" Foreground="#F5D0FE" FontSize="11"/>
                </StackPanel>
              </StackPanel>
            </Grid>
          </Border>
          <Border Grid.Row="1" Style="{StaticResource Card}">
            <DockPanel>
              <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
                <Button x:Name="btnSelAll" Content="Marcar tudo"/>
                <Button x:Name="btnSelNone" Content="Desmarcar tudo"/>
                <Button x:Name="btnCleanMgr" Content="Limpeza de Disco do Windows"/>
                <Button x:Name="btnHiber" Content="Desativar hibernação (libera GBs)"/>
              </WrapPanel>
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="0,0,6,0">
                <StackPanel x:Name="spClean"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </Grid>

        <!-- ===== AJUSTES DO WINDOWS ===== -->
        <ScrollViewer x:Name="pgPerf" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <StackPanel>
            <Border Style="{StaticResource Hero}">
              <StackPanel>
                <Border Style="{StaticResource Chip}" Background="#33FFFFFF" HorizontalAlignment="Left"><TextBlock Text="PLANO DE ENERGIA" FontSize="10" FontWeight="Black"/></Border>
                <TextBlock x:Name="txtPowerPlan" Text="--" FontSize="24" FontWeight="Black" Margin="0,10,0,14"/>
                <WrapPanel>
                  <Button x:Name="btnPlanBalanced" Style="{StaticResource Glass}" Content="Equilibrado"/>
                  <Button x:Name="btnPlanHigh" Style="{StaticResource Glass}" Content="Alto desempenho"/>
                  <Button x:Name="btnPlanUltimate" Style="{StaticResource Glass}" Background="White" Foreground="#6D28D9" FontWeight="Black" Content="DESEMPENHO MÁXIMO"/>
                </WrapPanel>
                <TextBlock Foreground="#F5D0FE" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,0" Text="Desempenho máximo deixa o processador sempre pronto, sem economizar energia, o que reduz travadinhas. Em notebook, gasta mais bateria e esquenta mais."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// AJUSTES DO WINDOWS" Style="{StaticResource Label}"/>
                <TextBlock Style="{StaticResource Desc}" Text="Deixa o Windows mais leve e limpo. Tudo pode ser desfeito, é só desligar. Alguns só valem depois de reiniciar ou sair da conta."/>
                <StackPanel x:Name="spTweaks"/>
              </StackPanel>
            </Border>
          </StackPanel></AdornerDecorator>

        </ScrollViewer>

        <!-- ===== INICIALIZAÇÃO ===== -->
        <Border x:Name="pgStart" Visibility="Collapsed" Style="{StaticResource Card}">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Style="{StaticResource Desc}" Text="Programas que abrem sozinhos quando o Windows liga deixam tudo mais lento e ocupam memória o tempo todo, até durante o jogo. Desative o que você não usa sempre: o programa continua instalado."/>
            <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
              <Button x:Name="btnStartDisable" Style="{StaticResource Danger}" Content="Desativar selecionado"/>
              <Button x:Name="btnStartEnable" Content="Ativar selecionado"/>
              <Button x:Name="btnStartRefresh" Content="Atualizar lista"/>
              <Button x:Name="btnTaskMgr" Content="Abrir Gerenciador de Tarefas"/>
            </WrapPanel>
            <DataGrid x:Name="gridStart">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Programa" Binding="{Binding Nome}" Width="*"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="110"/>
                <DataGridTextColumn Header="Origem" Binding="{Binding Origem}" Width="190"/>
                <DataGridTextColumn Header="Comando" Binding="{Binding Comando}" Width="2*"/>
              </DataGrid.Columns>
            </DataGrid>
          </DockPanel>
        </Border>

        <!-- ===== MANUTENÇÃO ===== -->
        <ScrollViewer x:Name="pgMaint" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<AdornerDecorator>
          <UniformGrid Columns="2">
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// REPARAR O WINDOWS" Style="{StaticResource Label}" Foreground="#E879F9"/>
                <TextBlock Style="{StaticResource Desc}" Text="Encontra e corrige arquivos corrompidos do sistema (causa comum de travadas e telas azuis). Abre numa janela separada e pode levar de 10 a 30 minutos."/>
                <Button x:Name="btnSfc" Content="Verificar arquivos do sistema (SFC)"/>
                <Button x:Name="btnDism" Content="Reparar imagem do Windows (DISM)"/>
                <Button x:Name="btnDismClean" Content="Limpar componentes antigos do Windows"/>
                <Button x:Name="btnChkdsk" Content="Verificar erros no disco (CHKDSK)"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// DISCOS" Style="{StaticResource Label}" Foreground="#E879F9"/>
                <TextBlock Style="{StaticResource Desc}" Text="Otimizar faz TRIM em SSD e desfragmenta HD, cada um do jeito certo. A saúde mostra se algum disco está dando sinal de defeito."/>
                <Button x:Name="btnDefrag" Content="Otimizar todos os discos"/>
                <Button x:Name="btnDiskHealth" Content="Ver saúde dos discos"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// SEGURANÇA E BACKUP" Style="{StaticResource Label}" Foreground="#E879F9"/>
                <TextBlock Style="{StaticResource Desc}" Text="O ponto de restauração deixa você voltar o Windows para como estava, se algum ajuste der problema."/>
                <Button x:Name="btnRestore" Style="{StaticResource Primary}" Content="Criar ponto de restauração"/>
                <Button x:Name="btnRstrui" Content="Voltar para um ponto de restauração"/>
                <Button x:Name="btnDefender" Content="Verificação rápida de vírus (Defender)"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// ATUALIZAÇÕES" Style="{StaticResource Label}" Foreground="#E879F9"/>
                <TextBlock Style="{StaticResource Desc}" Text="Programas e drivers desatualizados são causa comum de travamentos. O winget atualiza seus programas automaticamente."/>
                <Button x:Name="btnWinUpdate" Content="Abrir Windows Update"/>
                <Button x:Name="btnWingetList" Content="Ver programas desatualizados"/>
                <Button x:Name="btnWingetAll" Content="Atualizar todos os programas"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="// DIAGNÓSTICO" Style="{StaticResource Label}" Foreground="#E879F9"/>
                <TextBlock Style="{StaticResource Desc}" Text="Ferramentas do próprio Windows para descobrir por que o PC trava, reinicia sozinho ou a bateria não dura."/>
                <Button x:Name="btnReliab" Content="Histórico de erros e travamentos"/>
                <Button x:Name="btnBattery" Content="Relatório da bateria (notebook)"/>
                <Button x:Name="btnMemTest" Content="Testar a memória RAM (reinicia o PC)"/>
              </StackPanel>
            </Border>
          </UniformGrid></AdornerDecorator>

        </ScrollViewer>
      </Grid>

      <!-- REGISTRO -->
      <Border Grid.Row="3" Background="#B30D0919" CornerRadius="4" BorderBrush="#2C2350" BorderThickness="1" Margin="28,0,28,18">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="16,10,14,4">
            <Ellipse Width="7" Height="7" Fill="#39FF88" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Text="// REGISTRO DE ATIVIDADES" Style="{StaticResource Label}"/>
          </StackPanel>
          <TextBox x:Name="txtLog" Background="Transparent" Foreground="#B9B0DA" BorderThickness="0" FontFamily="Consolas" FontSize="12"
                   IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="12,0,12,8"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Linhas de scan (estáticas) e barra de varredura (animações extras) -->
    <Rectangle Grid.ColumnSpan="2" Fill="{StaticResource ScanBrush}" IsHitTestVisible="False" Opacity="0.7" Panel.ZIndex="50"/>
    <Canvas Grid.ColumnSpan="2" IsHitTestVisible="False" ClipToBounds="True" Panel.ZIndex="51">
      <Rectangle x:Name="scanBar" Width="4000" Height="160" Fill="{StaticResource ScanBarGrad}" Visibility="Collapsed">
        <Rectangle.RenderTransform><TranslateTransform Y="-200"/></Rectangle.RenderTransform>
      </Rectangle>
    </Canvas>

    <!-- Tela de acesso: só o nick, sem senha -->
    <Border x:Name="loginOverlay" Grid.ColumnSpan="2" Background="#F2120D21" Panel.ZIndex="99" Visibility="Collapsed">
      <Grid>
        <Rectangle Fill="{StaticResource GridBrush}"/>
        <Border x:Name="loginCard" Style="{StaticResource Hero}" Width="470" Margin="0" VerticalAlignment="Center" HorizontalAlignment="Center">
          <StackPanel>
            <TextBlock Text="// ACESSO AO SISTEMA" Style="{StaticResource Label}" Foreground="#F5D0FE"/>
            <TextBlock Text="IDENTIFIQUE-SE" FontSize="34" FontWeight="Black" Margin="0,8,0,4"/>
            <TextBlock Text="Digite seu nick. Não tem senha: é só para o painel saber como te chamar." Foreground="#F5D0FE" FontSize="12.5" TextWrapping="Wrap"/>
            <Border Background="#40000000" BorderBrush="#77FFFFFF" BorderThickness="1" CornerRadius="3" Margin="0,18,0,6" Padding="12,2">
              <Grid>
                <TextBlock Text="&gt;" FontFamily="Consolas" FontSize="18" Foreground="#E879F9" VerticalAlignment="Center"/>
                <TextBox x:Name="txtLoginNick" Margin="20,0,0,0" Background="Transparent" BorderThickness="0" Foreground="White" FontFamily="Consolas" FontSize="18" CaretBrush="#E879F9" MaxLength="20" Padding="0,7"/>
              </Grid>
            </Border>
            <TextBlock x:Name="txtLoginErr" Text="" Foreground="#FFB4CF" FontSize="11.5" Margin="0,0,0,12"/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnLogin" Style="{StaticResource PlayBtn}"/>
              <StackPanel VerticalAlignment="Center" Margin="14,0,0,0">
                <TextBlock Text="ENTRAR" FontWeight="Black" FontSize="16"/>
                <TextBlock Text="ou aperte Enter" Foreground="#F5D0FE" FontSize="11"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- Abertura estilo terminal -->
    <Border x:Name="bootOverlay" Grid.ColumnSpan="2" Background="#120D21" Panel.ZIndex="100">
      <Grid>
        <Rectangle Fill="{StaticResource GridBrush}"/>
        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="560">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="OPTIMIZER" FontWeight="Black" FontSize="52"/>
            <Border Background="{StaticResource PurpleGrad}" CornerRadius="2" Padding="12,0" Margin="12,8,0,8">
              <Border.Effect><DropShadowEffect Color="#D946EF" BlurRadius="24" ShadowDepth="0" Opacity="0.9"/></Border.Effect>
              <TextBlock Text="GBZ" FontWeight="Black" FontSize="34" VerticalAlignment="Center"/>
            </Border>
          </StackPanel>
          <TextBlock Text="&gt; by n0ctlow" FontFamily="Consolas" Foreground="#E879F9" FontSize="14" Margin="3,0,0,22"/>
          <TextBlock x:Name="txtBoot" FontFamily="Consolas" FontSize="13" Foreground="#B9B0DA" LineHeight="21" Text=""/>
          <ProgressBar x:Name="barBoot" Margin="0,18,0,0" Height="4"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
  </Border>
</Window>
'@

try {
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    [System.Windows.MessageBox]::Show("Erro ao abrir a interface:`n$($_.Exception.Message)", 'Optimizer GBZ', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    exit
}

$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = ($node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1).Value
    if ($name) { $ui[$name] = $window.FindName($name) }
}

# ------------------------------------------------------------------
# 4. Funções auxiliares (log, animações, registro)
# ------------------------------------------------------------------
$script:Busy = $false
$brushConv = New-Object System.Windows.Media.BrushConverter
function New-Brush([string]$hex) { $brushConv.ConvertFromString($hex) }
function New-Duration([int]$ms) { New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($ms)) }

$script:EaseOut = New-Object System.Windows.Media.Animation.CubicEase
$script:EaseOut.EasingMode = 'EaseOut'

function Update-UI {
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Barra que desliza suave até o valor novo
function Set-BarValue($Bar, [double]$Value) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = [math]::Max(0, [math]::Min($Bar.Maximum, $Value))
    $a.Duration = New-Duration 650
    $a.EasingFunction = $script:EaseOut
    $Bar.BeginAnimation([System.Windows.Controls.Primitives.RangeBase]::ValueProperty, $a)
}

# Medidor circular: o arco é um traço tracejado cujo deslocamento é animado
function Initialize-Gauge($G) {
    $w = [double]$G.Parent.Width
    $t = [double]$G.StrokeThickness
    $d = [math]::PI * ($w - $t) / $t
    $dc = New-Object System.Windows.Media.DoubleCollection
    $dc.Add($d); $dc.Add($d)
    $G.StrokeDashArray = $dc
    $G.StrokeDashOffset = $d
    $G.Tag = $d
}

$script:GaugeLast = @{}
function Set-Gauge($G, [double]$Pct) {
    if ($null -eq $G.Tag) { return }
    $Pct = [math]::Max(0, [math]::Min(100, $Pct))
    $key = $G.Name
    if ($script:GaugeLast.ContainsKey($key) -and [math]::Abs($script:GaugeLast[$key] - $Pct) -lt 1) { return }
    $script:GaugeLast[$key] = $Pct
    $d = [double]$G.Tag
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $d * (1 - $Pct / 100)
    $a.Duration = New-Duration 600
    $a.EasingFunction = $script:EaseOut
    $G.BeginAnimation([System.Windows.Shapes.Shape]::StrokeDashOffsetProperty, $a)
}

# Gráfico de linha ao vivo
$script:CpuHist = New-Object System.Collections.Generic.List[double]
$script:NetHist = New-Object System.Collections.Generic.List[double]
$script:SparkSlots = 40
function Add-Hist($List, [double]$Value) {
    $List.Add($Value)
    while ($List.Count -gt $script:SparkSlots) { $List.RemoveAt(0) }
}

function Draw-Spark($HostEl, $Line, $Area, $Values, [double]$Max) {
    $w = $HostEl.ActualWidth; $h = $HostEl.ActualHeight
    if ($w -le 0 -or $h -le 0 -or $Values.Count -lt 2) { return }
    if ($Max -le 0) { $Max = 1 }
    $step = $w / ($script:SparkSlots - 1)
    $offset = $script:SparkSlots - $Values.Count
    $pts = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $x = ($i + $offset) * $step
        $y = $h - 4 - ([math]::Min($Values[$i], $Max) / $Max) * ($h - 10)
        $pts.Add((New-Object System.Windows.Point $x, $y))
    }
    $Line.Points = $pts
    $ap = New-Object System.Windows.Media.PointCollection
    $ap.Add((New-Object System.Windows.Point ($offset * $step), $h))
    foreach ($pt in $pts) { $ap.Add($pt) }
    $ap.Add((New-Object System.Windows.Point (($Values.Count - 1 + $offset) * $step), $h))
    $Area.Points = $ap
}

function Update-Sparks {
    Draw-Spark $ui.sparkHost $ui.sparkCpu $ui.sparkCpuArea $script:CpuHist 100
    $max = 5
    if ($script:NetHist.Count -gt 0) { $max = [math]::Max(5, (($script:NetHist | Measure-Object -Maximum).Maximum) * 1.2) }
    Draw-Spark $ui.sparkNetHost $ui.sparkNet $ui.sparkNetArea $script:NetHist $max
}

# Números que sobem/descem contando (efeito de contador)
$script:Tweens = @{}
$script:NumCur = @{}
$script:TweenTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TweenTimer.Interval = [TimeSpan]::FromMilliseconds(30)
$script:TweenTimer.Add_Tick({
    $done = @()
    foreach ($k in @($script:Tweens.Keys)) {
        $t = $script:Tweens[$k]
        $t.Step++
        $pr = [math]::Min(1, $t.Step / $t.Steps)
        $ease = 1 - [math]::Pow(1 - $pr, 3)
        $t.Cur = $t.From + ($t.To - $t.From) * $ease
        $t.El.Text = ('{0:N0}' -f $t.Cur) + $t.Suffix
        if ($pr -ge 1) { $done += $k }
    }
    foreach ($k in $done) { $script:NumCur[$k] = $script:Tweens[$k].To; $script:Tweens.Remove($k) }
    if ($script:Tweens.Count -eq 0) { $script:TweenTimer.Stop() }
})
function Set-CountText($El, [double]$To, [string]$Suffix = '%') {
    $k = $El.Name
    $from = 0.0
    if ($script:Tweens.ContainsKey($k)) { $from = $script:Tweens[$k].Cur }
    elseif ($script:NumCur.ContainsKey($k)) { $from = $script:NumCur[$k] }
    if ([math]::Abs($from - $To) -lt 0.5 -and $El.Text) { return }
    $script:Tweens[$k] = @{ El = $El; From = $from; To = $To; Cur = $from; Step = 0; Steps = 20; Suffix = $Suffix }
    if (-not $script:TweenTimer.IsEnabled) { $script:TweenTimer.Start() }
}

# Subtítulo digitado como num terminal
$script:TwTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TwTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$script:TwTimer.Add_Tick({
    $script:TwPos = [math]::Min($script:TwText.Length, $script:TwPos + 2)
    $ui.txtPageSub.Text = $script:TwText.Substring(0, $script:TwPos)
    if ($script:TwPos -ge $script:TwText.Length) { $script:TwTimer.Stop() }
})
function Start-Typewriter([string]$Text) {
    $script:TwText = "> $Text"
    $script:TwPos = 0
    $ui.txtPageSub.Text = ''
    $script:TwTimer.Start()
}

# Logo com efeito glitch de vez em quando
$script:Rnd = New-Object System.Random
$script:GlitchFrames = 0
$script:GlitchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:GlitchTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:GlitchTimer.Add_Tick({
    if ($script:GlitchFrames -le 0) {
        $script:GlitchFrames = 7
        $script:GlitchTimer.Interval = [TimeSpan]::FromMilliseconds(45)
    }
    $script:GlitchFrames--
    if ($script:GlitchFrames -gt 0) {
        $ui.logoGlitchA.Opacity = 0.85; $ui.logoGlitchB.Opacity = 0.85
        $ui.logoGlitchA.RenderTransform.X = $script:Rnd.Next(-5, 6)
        $ui.logoGlitchB.RenderTransform.X = $script:Rnd.Next(-5, 6)
        $ui.logoMain.RenderTransform.X = $script:Rnd.Next(-2, 3)
    } else {
        $ui.logoGlitchA.Opacity = 0; $ui.logoGlitchB.Opacity = 0
        $ui.logoGlitchA.RenderTransform.X = 0; $ui.logoGlitchB.RenderTransform.X = 0; $ui.logoMain.RenderTransform.X = 0
        $script:GlitchTimer.Interval = [TimeSpan]::FromMilliseconds($script:Rnd.Next(3500, 7000))
    }
})

# Moldura HUD nos cards: aparece "travando a mira" quando a página abre
$script:AdornedPages = @{}
$script:PageAdorners = @{}
$script:AdornerMap = @{}
function Set-HudAnim($A, [double]$Ext, [double]$Glow, [int]$DelayMs = 0, [bool]$FromZero = $false) {
    $a1 = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a1.To = $Ext; $a1.Duration = New-Duration 260; $a1.EasingFunction = $script:EaseOut
    $a1.BeginTime = [TimeSpan]::FromMilliseconds($DelayMs)
    $a2 = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a2.To = $Glow; $a2.Duration = New-Duration 260
    $a2.BeginTime = [TimeSpan]::FromMilliseconds($DelayMs)
    if ($FromZero) { $a1.From = 0; $a2.From = 0 }
    $A.BeginAnimation([HudAdorner]::ExtentProperty, $a1)
    $A.BeginAnimation([HudAdorner]::GlowProperty, $a2)
}

function Get-CardBorders($Root) {
    $cardStyle = $window.FindResource('Card'); $heroStyle = $window.FindResource('Hero')
    $list = New-Object System.Collections.ArrayList
    $q = New-Object System.Collections.Queue
    $q.Enqueue($Root)
    while ($q.Count -gt 0) {
        $n = $q.Dequeue()
        if ($n -is [System.Windows.Controls.Border] -and (($n.Style -eq $cardStyle) -or ($n.Style -eq $heroStyle))) { [void]$list.Add($n) }
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($n)) { if ($c -is [System.Windows.DependencyObject]) { $q.Enqueue($c) } }
    }
    return ,$list
}

function Add-HudToPage([string]$Nav) {
    if (-not $script:HudOk -or $script:AdornedPages.ContainsKey($Nav)) { return }
    $page = $ui[$script:Pages[$Nav].Page]
    $page.UpdateLayout()
    $ads = @()
    foreach ($b in (Get-CardBorders $page)) {
        $layer = [System.Windows.Documents.AdornerLayer]::GetAdornerLayer($b)
        if (-not $layer) { continue }
        $ad = New-Object HudAdorner $b
        $layer.Add($ad)
        $script:AdornerMap[$b.GetHashCode()] = $ad
        $b.Add_MouseEnter({ param($s, $e) $a = $script:AdornerMap[$s.GetHashCode()]; if ($a) { Set-HudAnim $a 30 1 } })
        $b.Add_MouseLeave({ param($s, $e) $a = $script:AdornerMap[$s.GetHashCode()]; if ($a) { Set-HudAnim $a 14 0.55 } })
        $ads += $ad
    }
    $script:PageAdorners[$Nav] = $ads
    $script:AdornedPages[$Nav] = $true
}

# Indicador neon do menu que desliza até a aba escolhida
function Move-NavIndicator([string]$Nav) {
    try {
        $btn = $ui[$Nav]
        $pt = $btn.TranslatePoint((New-Object System.Windows.Point 0, 0), $ui.navHost)
        $y = $pt.Y + ($btn.ActualHeight - $ui.navIndicator.Height) / 2
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.To = $y; $a.Duration = New-Duration 320
        $e = New-Object System.Windows.Media.Animation.BackEase; $e.EasingMode = 'EaseOut'; $e.Amplitude = 0.35
        $a.EasingFunction = $e
        $ui.navIndicator.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $a)
        $ui.navIndicator.Opacity = 1
    } catch {}
}

# Animações extras: só rodam se o usuário ligar
$script:AmbientOn = $false
function New-Loop([double]$From, [double]$To, [double]$Seconds, [bool]$Reverse = $true) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation $From, $To, (New-Duration ([int]($Seconds * 1000)))
    $a.AutoReverse = $Reverse
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    if ($Reverse) {
        $e = New-Object System.Windows.Media.Animation.SineEase
        $e.EasingMode = 'EaseInOut'
        $a.EasingFunction = $e
    }
    return $a
}

function Set-Particles([bool]$On) {
    if ($On -and -not $script:ParticlesBuilt) {
        $script:ParticlesBuilt = $true
        $colors = '#E879F9', '#22D3EE', '#A855F7', '#39FF88'
        for ($i = 0; $i -lt 26; $i++) {
            $r = New-Object System.Windows.Shapes.Rectangle
            $sz = $script:Rnd.Next(2, 5)
            $r.Width = $sz; $r.Height = $sz
            $r.Fill = New-Brush $colors[$i % 4]
            $r.Opacity = 0.25 + $script:Rnd.NextDouble() * 0.5
            [System.Windows.Controls.Canvas]::SetLeft($r, $script:Rnd.Next(0, 1800))
            $r.RenderTransform = New-Object System.Windows.Media.TranslateTransform 0, 1000
            [void]$ui.bgParticles.Children.Add($r)
        }
    }
    $ui.bgParticles.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    foreach ($r in $ui.bgParticles.Children) {
        if ($On) {
            $dur = 9 + $script:Rnd.NextDouble() * 10
            $a = New-Loop 1000 -30 $dur $false
            $a.BeginTime = [TimeSpan]::FromSeconds(-1 * $script:Rnd.NextDouble() * $dur)
            $r.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $a)
        } else {
            $r.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
        }
    }
}

function Set-Ambient([bool]$On) {
    $script:AmbientOn = $On
    $TX = [System.Windows.Media.TranslateTransform]::XProperty
    $TY = [System.Windows.Media.TranslateTransform]::YProperty
    $OP = [System.Windows.UIElement]::OpacityProperty
    $list = @(
        @{ O = $ui.bgOrb1.RenderTransform;  P = $TX; A = { New-Loop -80 90 10 } }
        @{ O = $ui.bgOrb1.RenderTransform;  P = $TY; A = { New-Loop 0 70 8 } }
        @{ O = $ui.bgOrb2.RenderTransform;  P = $TX; A = { New-Loop 0 120 12 } }
        @{ O = $ui.bgOrb2.RenderTransform;  P = $TY; A = { New-Loop 40 -60 9 } }
        @{ O = $ui.bgWaves.RenderTransform; P = $TX; A = { New-Loop -120 40 14 } }
        @{ O = $ui.heroPad.RenderTransform; P = $TY; A = { New-Loop -9 9 2.2 } }
        @{ O = $ui.star1; P = $OP; A = { New-Loop 0.1 1 1.1 } }
        @{ O = $ui.star2; P = $OP; A = { New-Loop 1 0.1 0.9 } }
        @{ O = $ui.star3; P = $OP; A = { New-Loop 0.2 1 0.8 } }
        @{ O = $ui.logoBadge.Effect; P = [System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty; A = { New-Loop 6 24 1.3 } }
        @{ O = $ui.scanBar.RenderTransform; P = $TY; A = { New-Loop -200 1100 7 $false } }
        @{ O = $ui.gRing1.RenderTransform; P = [System.Windows.Media.RotateTransform]::AngleProperty; A = { New-Loop 0 360 22 $false } }
        @{ O = $ui.gRing2.RenderTransform; P = [System.Windows.Media.RotateTransform]::AngleProperty; A = { New-Loop 360 0 26 $false } }
        @{ O = $ui.gRing3.RenderTransform; P = [System.Windows.Media.RotateTransform]::AngleProperty; A = { New-Loop 0 360 30 $false } }
        @{ O = $ui.gRing4.RenderTransform; P = [System.Windows.Media.RotateTransform]::AngleProperty; A = { New-Loop 360 0 18 $false } }
        @{ O = $ui.gRing5.RenderTransform; P = [System.Windows.Media.RotateTransform]::AngleProperty; A = { New-Loop 0 360 16 $false } }
    )
    $ui.scanBar.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    try { Set-Particles $On } catch {}
    foreach ($it in $list) {
        try {
            if ($On) { $it.O.BeginAnimation($it.P, (& $it.A)) } else { $it.O.BeginAnimation($it.P, $null) }
        } catch {}
    }
}

# Entrada de página: aparece deslizando de baixo
function Invoke-EnterAnim($Element, [int]$DelayMs = 0, [int]$Offset = 16) {
    $Element.Opacity = 0
    $tt = New-Object System.Windows.Media.TranslateTransform 0, $Offset
    $Element.RenderTransform = $tt
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, (New-Duration 280)
    $fade.BeginTime = [TimeSpan]::FromMilliseconds($DelayMs)
    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation $Offset, 0, (New-Duration 340)
    $slide.BeginTime = [TimeSpan]::FromMilliseconds($DelayMs)
    $slide.EasingFunction = $script:EaseOut
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Start-Pulse($Element) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0.25, (New-Duration 550)
    $a.AutoReverse = $true
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
}
function Stop-Pulse($Element) {
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $Element.Opacity = 1
}

function Write-Log([string]$Message, [string]$Kind = 'info') {
    $prefix = switch ($Kind) { 'ok' { '[OK] ' } 'warn' { '[!] ' } 'err' { '[ERRO] ' } default { '' } }
    $ui.txtLog.AppendText("[$(Get-Date -Format HH:mm:ss)] $prefix$Message`r`n")
    $ui.txtLog.ScrollToEnd()
    Update-UI
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$([int]$Bytes) B"
}

function Show-Msg([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    return [System.Windows.MessageBox]::Show($window, $Text, 'Optimizer GBZ', [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon)
}

function Confirm-Action([string]$Text) {
    return ((Show-Msg $Text 'YesNo' 'Warning') -eq 'Yes')
}

function Set-Status([string]$Text, [bool]$Working) {
    $ui.txtStatus.Text = $Text
    if ($Working) {
        $ui.dotStatus.Visibility = 'Collapsed'
        $ui.spinStatus.Visibility = 'Visible'
        $rot = New-Object System.Windows.Media.RotateTransform
        $ui.spinStatus.RenderTransform = $rot
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 360, (New-Duration 800)
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
        $window.Cursor = [System.Windows.Input.Cursors]::AppStarting
    } else {
        $ui.spinStatus.Visibility = 'Collapsed'
        $ui.dotStatus.Visibility = 'Visible'
        $window.Cursor = $null
    }
    Update-UI
}

function Invoke-Task([string]$Label, [scriptblock]$Action) {
    if ($script:Busy) { Write-Log 'Aguarde a tarefa atual terminar.' 'warn'; return }
    $script:Busy = $true
    Set-Status "$Label..." $true
    try { & $Action }
    catch { Write-Log $_.Exception.Message 'err' }
    finally {
        $script:Busy = $false
        Set-Status 'Pronto' $false
    }
}

function Start-ConsoleTask([string]$Title, [string]$Command) {
    $body = @"
`$host.UI.RawUI.WindowTitle = 'Optimizer GBZ - $Title'
Write-Host '== $Title ==' -ForegroundColor Cyan
Write-Host ''
$Command
Write-Host ''
Write-Host 'Concluído. Você já pode fechar esta janela.' -ForegroundColor Green
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    Start-Process powershell.exe -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -EncodedCommand $encoded"
    Write-Log "Abrindo janela: $Title (acompanhe por lá)."
}

function Get-Reg([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Remove-Reg([string]$Path, [string]$Name) {
    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
}


# Linha de resultado colorida (diagnóstico, ping, DNS)
function New-ResultRow([string]$Level, [string]$Text, [string]$Right = '', [int]$Index = 0) {
    $color = switch ($Level) { 'ok' { '#39FF88' } 'warn' { '#FACC15' } 'bad' { '#FF4D6D' } default { '#D946EF' } }
    $glyph = switch ($Level) { 'ok' { [string][char]0xE73E } 'warn' { [string][char]0xE7BA } 'bad' { [string][char]0xE711 } default { [string][char]0xE946 } }
    $b = New-Object System.Windows.Controls.Border
    $b.Background = New-Brush '#241B40'
    $b.BorderBrush = New-Brush '#33295A'
    $b.BorderThickness = New-Object System.Windows.Thickness 1
    $b.CornerRadius = New-Object System.Windows.CornerRadius 9
    $b.Padding = New-Object System.Windows.Thickness 12, 9, 12, 9
    $b.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        [void]$g.ColumnDefinitions.Add($cd)
    }
    $ic = New-Object System.Windows.Controls.TextBlock
    $ic.Text = $glyph; $ic.FontFamily = 'Segoe MDL2 Assets'; $ic.Foreground = New-Brush $color
    $ic.Margin = New-Object System.Windows.Thickness 0, 2, 12, 0; $ic.FontSize = 14
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text = $Text; $tx.TextWrapping = 'Wrap'; $tx.FontSize = 13
    [System.Windows.Controls.Grid]::SetColumn($tx, 1)
    $rt = New-Object System.Windows.Controls.TextBlock
    $rt.Text = $Right; $rt.FontFamily = 'Bahnschrift'; $rt.FontWeight = 'Bold'; $rt.Foreground = New-Brush $color
    $rt.Margin = New-Object System.Windows.Thickness 12, 0, 0, 0; $rt.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($rt, 2)
    [void]$g.Children.Add($ic); [void]$g.Children.Add($tx); [void]$g.Children.Add($rt)
    $b.Child = $g
    Invoke-EnterAnim $b ($Index * 60) 10
    return $b
}

# ------------------------------------------------------------------
# 5. Monitoramento ao vivo
# ------------------------------------------------------------------
function Get-MemUsedMB {
    $os = Get-CimInstance Win32_OperatingSystem
    return ([double]$os.TotalVisibleMemorySize - [double]$os.FreePhysicalMemory) / 1024
}

function Get-ActiveAdapters {
    return @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
}

$script:LastStamp = $null
function Update-Stats {
    try {
        $S = $script:S
        if (-not $S.Stamp -or ($S.Stamp -eq $script:LastStamp)) { return }
        $script:LastStamp = $S.Stamp

        $cpu = [double]$S.Cpu
        Set-CountText $ui.txtCpu $cpu '%'
        $ui.txtCpuSpark.Text = "$([int]$cpu)%"
        Set-Gauge $ui.gCpu $cpu
        Add-Hist $script:CpuHist $cpu

        $totalKB = [double]$S.TotalKB
        $freeKB  = [double]$S.FreeKB
        if ($totalKB -gt 0) {
            $usedPct = [math]::Round((($totalKB - $freeKB) / $totalKB) * 100)
            $ramText = '{0:N1} de {1:N1} GB' -f (($totalKB - $freeKB) / 1MB), ($totalKB / 1MB)
            Set-CountText $ui.txtRam $usedPct '%'
            $ui.txtRam.Foreground = if ($usedPct -ge 85) { New-Brush '#FF4D6D' } else { New-Brush '#FFFFFF' }
            Set-Gauge $ui.gRam $usedPct
            $ui.txtRamSub.Text = $ramText
            $ui.txtMemDetail.Text = "RAM em uso: $ramText ($usedPct%)"
            Set-BarValue $ui.barMem2 $usedPct
        }

        if ($S.DiskSize -gt 0) {
            $dPct = [math]::Round((($S.DiskSize - $S.DiskFree) / $S.DiskSize) * 100)
            $ui.txtDiskLabel.Text = "DISCO $($env:SystemDrive)"
            Set-CountText $ui.txtDisk $dPct '%'
            $ui.txtDisk.Foreground = if ($dPct -ge 90) { New-Brush '#FF4D6D' } else { New-Brush '#FFFFFF' }
            Set-Gauge $ui.gDisk $dPct
            $ui.txtDiskSub.Text = "$(Format-Size $S.DiskFree) livres"
            $ui.txtCleanDisk.Text = "Espaço livre no disco $($env:SystemDrive): $(Format-Size $S.DiskFree) de $(Format-Size $S.DiskSize)"
        }

        if ($S.Boot) {
            $up = (Get-Date) - $S.Boot
            $ui.txtUptime.Text = if ($up.Days -gt 0) { '{0}d {1}h' -f $up.Days, $up.Hours } else { '{0}h {1}min' -f $up.Hours, $up.Minutes }
            $ui.txtUptimeSub.Text = if ($up.TotalDays -ge 3) { 'Reinicie o PC: ajuda contra travadinhas!' } else { "desde $($S.Boot.ToString('dd/MM HH:mm'))" }
        }

        # Rede (valores medidos em segundo plano)
        switch ($S.ConnType) {
            'eth'  { $ui.txtConn.Text = 'Cabo'; $ui.txtConn.Foreground = New-Brush '#39FF88'; $ui.txtConnSub.Text = $S.ConnDesc }
            'wifi' {
                $sig = $S.WifiSig
                $ui.txtConn.Text = if ($sig) { "Wi-Fi $sig%" } else { 'Wi-Fi' }
                $ui.txtConn.Foreground = if ($sig -and [int]$sig -lt 60) { New-Brush '#FF4D6D' } else { New-Brush '#FACC15' }
                $ui.txtConnSub.Text = 'Wi-Fi oscila mais que cabo. Para jogar, cabo é sempre melhor.'
            }
            'none' { $ui.txtConn.Text = 'Sem rede'; $ui.txtConn.Foreground = New-Brush '#FF4D6D'; $ui.txtConnSub.Text = '' }
        }
        if ($null -ne $S.Down) {
            $ui.txtDown.Text = '{0:N1} Mbps' -f $S.Down
            $ui.txtUp.Text   = '{0:N1} Mbps' -f $S.Up
            Add-Hist $script:NetHist ([double]$S.Down)
            $ui.txtNetPeak.Text = 'pico recente: {0:N1} Mbps' -f (($script:NetHist | Measure-Object -Maximum).Maximum)
        }
        Update-Sparks
    } catch {}
}

# Monitoramento em segundo plano: as consultas lentas (WMI, rede) rodam numa
# thread separada, e a interface só lê os valores prontos. Assim a janela não trava.
$script:S = [hashtable]::Synchronized(@{ Run = $true })
$script:BgScript = {
    param($S)
    $tick = 0; $prev = $null; $names = @()
    while ($S.Run) {
        try {
            $S.Cpu = [double]((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average)
            $os = Get-CimInstance Win32_OperatingSystem
            $S.TotalKB = [double]$os.TotalVisibleMemorySize
            $S.FreeKB  = [double]$os.FreePhysicalMemory
            $S.Boot    = $os.LastBootUpTime
            $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
            if ($d) { $S.DiskSize = [double]$d.Size; $S.DiskFree = [double]$d.FreeSpace }
            if ((($tick % 5) -eq 0) -or ($names.Count -eq 0) -or $S.RefreshNet) {
                $S.RefreshNet = $false
                $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
                $names = @($ad | ForEach-Object { $_.Name })
                $eth  = $ad | Where-Object { "$($_.PhysicalMediaType)" -match '802\.3' } | Select-Object -First 1
                $wifi = $ad | Where-Object { "$($_.PhysicalMediaType)" -match '802\.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' } | Select-Object -First 1
                if ($eth) { $S.ConnType = 'eth'; $S.ConnDesc = "$($eth.InterfaceDescription) - $($eth.LinkSpeed)" }
                elseif ($wifi) {
                    $S.ConnType = 'wifi'; $sig = ''
                    $w = (netsh wlan show interfaces) -join "`n"
                    if ($w -match '(\d+)\s*%') { $sig = $Matches[1] }
                    $S.WifiSig = $sig
                } else { $S.ConnType = 'none' }
            }
            $st = @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.Name })
            $rx = [double]($st | Measure-Object -Property ReceivedBytes -Sum).Sum
            $tx = [double]($st | Measure-Object -Property SentBytes -Sum).Sum
            $now = Get-Date
            if ($prev) {
                $sec = ($now - $prev.T).TotalSeconds
                if ($sec -gt 0) {
                    $S.Down = [math]::Max(0, ($rx - $prev.Rx) * 8 / $sec / 1e6)
                    $S.Up   = [math]::Max(0, ($tx - $prev.Tx) * 8 / $sec / 1e6)
                }
            }
            $prev = @{ T = $now; Rx = $rx; Tx = $tx }
            $S.Stamp = $now
        } catch {}
        $tick++
        for ($i = 0; ($i -lt 20) -and $S.Run; $i++) { Start-Sleep -Milliseconds 100 }
    }
}

function Start-Monitor {
    $script:BgPS = [powershell]::Create()
    [void]$script:BgPS.AddScript($script:BgScript).AddArgument($script:S)
    $script:BgHandle = $script:BgPS.BeginInvoke()
}

function Stop-Monitor {
    $script:S.Run = $false
    try { $script:BgPS.Stop(); $script:BgPS.Dispose() } catch {}
}

# Ping sem travar a interface (assíncrono)
$script:Pinger = New-Object System.Net.NetworkInformation.Ping
$script:PingTask = $null
function Update-Ping {
    try {
        if ($script:PingTask -and $script:PingTask.IsCompleted) {
            $ok = $false
            if (-not $script:PingTask.IsFaulted) {
                $r = $script:PingTask.Result
                if ($r.Status -eq 'Success') {
                    $ok = $true
                    $ms = [int]$r.RoundtripTime
                    $color = if ($ms -lt 50) { '#39FF88' } elseif ($ms -lt 100) { '#FACC15' } else { '#FF4D6D' }
                    foreach ($t in $ui.txtPing, $ui.txtPing2, $ui.txtPingChip) { $t.Text = "$ms ms" }
                    $ui.txtPing2.Foreground = New-Brush $color
                    $ui.dotPingChip.Fill = New-Brush $color
                    Set-Gauge $ui.gPing ([math]::Min(100, $ms / 150 * 100))
                }
            }
            if (-not $ok) {
                foreach ($t in $ui.txtPing, $ui.txtPing2, $ui.txtPingChip) { $t.Text = 'sem resposta' }
                $ui.txtPing2.Foreground = New-Brush '#FF4D6D'
                $ui.dotPingChip.Fill = New-Brush '#FF4D6D'
                Set-Gauge $ui.gPing 0
            }
            $script:PingTask = $null
        }
        if (-not $script:PingTask) { $script:PingTask = $script:Pinger.SendPingAsync('1.1.1.1', 1500) }
    } catch { $script:PingTask = $null }
}

function Update-NetInfo([bool]$Full) {
    # A leitura da rede agora acontece em segundo plano (Start-Monitor).
    if ($Full) { $script:S.RefreshNet = $true }
}

function Get-SysInfo {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = (Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ', '
    $disks = @(foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $type = switch ("$($pd.MediaType)") { 'SSD' { 'SSD' } 'HDD' { 'HD' } default { 'disco' } }
        "$($pd.FriendlyName) ($type, $(Format-Size $pd.Size))"
    })
    $lines = @(
        "Computador:  $($cs.Name)"
        "Sistema:  $($os.Caption) (build $($os.BuildNumber))"
        "Processador:  $($cpu.Name.Trim())  -  $($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) threads"
        "Placa de vídeo:  $gpu"
        "Memória RAM:  $(Format-Size $cs.TotalPhysicalMemory)"
        "Discos:  $($disks -join '  |  ')"
    )
    return ($lines -join "`n")
}

# ------------------------------------------------------------------
# 6. Memória RAM e processos
# ------------------------------------------------------------------
function Invoke-FreeRam {
    $before = Get-MemUsedMB
    Write-Log 'Liberando memória RAM...'
    $count  = [GabTools]::TrimWorkingSets()
    $status = [GabTools]::PurgeStandbyList()
    Start-Sleep -Milliseconds 800
    $after = Get-MemUsedMB
    $diff  = [math]::Max(0, $before - $after)
    Write-Log ('Memória otimizada em {0} programas. RAM em uso: {1:N0} MB -> {2:N0} MB ({3:N0} MB liberados).' -f $count, $before, $after, $diff) 'ok'
    if ($status -ne 0) { Write-Log ('A lista de espera não pôde ser limpa (código 0x{0:X8}).' -f $status) 'warn' }
    Update-Stats
    return $diff
}

$script:ProtectedProcs = @('system','idle','registry','smss','csrss','wininit','winlogon','services','lsass','svchost',
                           'dwm','fontdrvhost','memory compression','sihost','ctfmon','msmpeng','securityhealthservice','explorer')

function Update-ProcList {
    $list = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 40 | ForEach-Object {
        $cpu = 0
        if ($_.CPU) { $cpu = [math]::Round($_.CPU, 1) }
        [pscustomobject]@{ Nome = $_.ProcessName; PID = $_.Id; RamMB = [math]::Round($_.WorkingSet64 / 1MB, 0); CpuSeg = $cpu }
    }
    $ui.gridProc.ItemsSource = @($list)
}

# ------------------------------------------------------------------
# 7. Limpeza
# ------------------------------------------------------------------
$L  = $env:LOCALAPPDATA
$W  = $env:windir
$PD = $env:ProgramData
$script:Chromium = @("$L\Google\Chrome\User Data", "$L\Microsoft\Edge\User Data", "$L\BraveSoftware\Brave-Browser\User Data", "$L\Vivaldi\User Data")

$script:CleanItems = @(
    @{ Nome = 'Arquivos temporários do usuário'; Desc = 'Pasta TEMP da sua conta. Arquivos em uso são ignorados.'; Def = $true; Quick = $true
       Paths = { @($env:TEMP) } }
    @{ Nome = 'Arquivos temporários do Windows'; Desc = 'Pasta Windows\Temp.'; Def = $true; Quick = $true
       Paths = { @("$W\Temp") } }
    @{ Nome = 'Cache do Windows Update'; Desc = 'Instaladores de atualizações já aplicadas. O Windows baixa de novo se precisar.'; Def = $true
       Paths = { @("$W\SoftwareDistribution\Download") }
       Pre   = { Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue }
       Post  = { Start-Service wuauserv, bits -ErrorAction SilentlyContinue } }
    @{ Nome = 'Cache de Otimização de Entrega'; Desc = 'Pedaços de atualizações que o Windows compartilha com outros PCs.'; Def = $true
       Paths = { @("$W\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache", "$W\SoftwareDistribution\DeliveryOptimization") }
       Pre   = { Stop-Service DoSvc -Force -ErrorAction SilentlyContinue }
       Post  = { Start-Service DoSvc -ErrorAction SilentlyContinue } }
    @{ Nome = 'Relatórios de erro do Windows'; Desc = 'Relatórios de travamentos de programas já enviados ou descartados.'; Def = $true; Quick = $true
       Paths = { @("$PD\Microsoft\Windows\WER\ReportArchive", "$PD\Microsoft\Windows\WER\ReportQueue", "$PD\Microsoft\Windows\WER\Temp", "$L\CrashDumps") } }
    @{ Nome = 'Arquivos de despejo de memória (dumps)'; Desc = 'Arquivos criados em telas azuis e falhas. Podem ocupar vários GB.'; Def = $true; Quick = $true
       Paths = { @("$W\Minidump", "$W\MEMORY.DMP", "$W\LiveKernelReports") } }
    @{ Nome = 'Cache de miniaturas'; Desc = 'Prévias de fotos e vídeos. O Windows recria quando você abrir as pastas.'; Def = $true
       Paths = { @("$L\Microsoft\Windows\Explorer\thumbcache_*.db", "$L\Microsoft\Windows\Explorer\iconcache_*.db") } }
    @{ Nome = 'Cache dos navegadores'; Desc = 'Chrome, Edge, Brave, Vivaldi, Opera e Firefox. Não apaga senhas, histórico nem logins. Feche os navegadores antes.'; Def = $true
       Paths = {
           $p = foreach ($b in $script:Chromium) { foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') { "$b\*\$sub" } }
           @($p) + @("$L\Opera Software\*\Cache", "$env:APPDATA\Opera Software\*\Cache", "$L\Mozilla\Firefox\Profiles\*\cache2")
       } }
    @{ Nome = 'Cache de shaders (jogos e placa de vídeo)'; Desc = 'DirectX, NVIDIA, AMD e Intel. Ajuda quando um jogo começa a travar depois de atualizar o driver, mas os jogos podem engasgar um pouco na primeira vez que abrirem.'; Def = $false
       Paths = { @("$L\D3DSCache", "$L\NVIDIA\DXCache", "$L\NVIDIA\GLCache", "$L\AMD\DxCache", "$L\AMD\GLCache", "$L\Intel\ShaderCache") } }
    @{ Nome = 'Instaladores de driver extraídos'; Desc = 'Pastas C:\NVIDIA e C:\AMD que sobram depois de instalar drivers de vídeo.'; Def = $false
       Paths = { @("$env:SystemDrive\NVIDIA", "$env:SystemDrive\AMD") } }
    @{ Nome = 'Lixeira'; Desc = 'Esvazia a lixeira de todos os discos. Não tem como desfazer.'; Def = $false
       Paths  = { @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\$Recycle.Bin' }) }
       Custom = { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } }
)

$script:Forbidden = @("$env:SystemDrive\", $env:windir, "$env:windir\System32", $env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)},
                      $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, "$env:SystemDrive\Users", $env:PUBLIC) |
                    Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

function Test-SafePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $n = $Path.TrimEnd('\').ToLower()
    if ($n.Length -lt 6) { return $false }
    return ($script:Forbidden -notcontains $n)
}

function Resolve-CleanTargets($Item) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(& $Item.Paths)) {
        if (-not $p) { continue }
        if ($p.Contains('*')) {
            foreach ($r in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
                if (Test-SafePath $r.FullName) { $out.Add($r.FullName) }
            }
        } elseif ((Test-SafePath $p) -and (Test-Path -LiteralPath $p)) {
            $out.Add($p)
        }
    }
    return ,$out
}

function Get-TargetsSize($Targets) {
    [double]$sum = 0
    foreach ($t in $Targets) {
        if (Test-Path -LiteralPath $t -PathType Container) {
            $m = Get-ChildItem -LiteralPath $t -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($m.Sum) { $sum += $m.Sum }
        } else {
            $f = Get-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
            if ($f -and -not $f.PSIsContainer) { $sum += $f.Length }
        }
        Update-UI
    }
    return $sum
}

# Apaga uma pasta ou arquivo sem passar pelo cmd e sem seguir atalhos de pasta
# (junction/symlink): se for um atalho, remove só o atalho, nunca o destino dele.
$script:DelCount = 0
function Remove-SafeTree([string]$Path) {
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) } else { [IO.File]::Delete($item.FullName) }
            return
        }
        if ($item.PSIsContainer) {
            foreach ($c in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)) { Remove-SafeTree $c.FullName }
            [IO.Directory]::Delete($item.FullName, $false)
        } else {
            if ($item.IsReadOnly) { $item.IsReadOnly = $false }
            [IO.File]::Delete($item.FullName)
        }
    } catch {}
    $script:DelCount++
    if (($script:DelCount % 250) -eq 0) { Update-UI }
}

function Remove-Targets($Targets) {
    foreach ($t in $Targets) {
        if (Test-Path -LiteralPath $t -PathType Container) {
            foreach ($c in @(Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue)) {
                Remove-SafeTree $c.FullName
            }
        } else {
            Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
        }
        Update-UI
    }
}

function Invoke-Clean($Items) {
    [double]$total = 0
    foreach ($it in $Items) {
        Write-Log "Limpando: $($it.Nome)..."
        try {
            $targets = Resolve-CleanTargets $it
            $before  = Get-TargetsSize $targets
            try {
                if ($it.Pre) { & $it.Pre }
                if ($it.Custom) { & $it.Custom } else { Remove-Targets $targets }
            } finally {
                if ($it.Post) { & $it.Post }
            }
            $after = Get-TargetsSize (Resolve-CleanTargets $it)
            $freed = [math]::Max(0, $before - $after)
            $total += $freed
            if ($it.SizeLabel) { $it.SizeLabel.Text = if ($after -gt 0) { "$(Format-Size $after) (em uso)" } else { 'limpo' } }
            Write-Log "$($it.Nome): $(Format-Size $freed) liberados." 'ok'
        } catch {
            Write-Log "$($it.Nome): $($_.Exception.Message)" 'err'
        }
    }
    return $total
}

function New-SwitchContent([string]$Title, [string]$Desc, $ExtraLabel) {
    $sp  = New-Object System.Windows.Controls.StackPanel
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $Title; $t1.FontSize = 14; $t1.FontWeight = 'SemiBold'; $t1.TextWrapping = 'Wrap'
    [void]$row.Children.Add($t1)
    if ($ExtraLabel -is [ref]) {
        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = ''; $t2.Margin = New-Object System.Windows.Thickness 10, 0, 0, 0
        $t2.Foreground = New-Brush '#D946EF'; $t2.FontFamily = 'Bahnschrift'; $t2.FontSize = 13; $t2.VerticalAlignment = 'Center'
        [void]$row.Children.Add($t2)
        $ExtraLabel.Value = $t2
    }
    $t3 = New-Object System.Windows.Controls.TextBlock
    $t3.Text = $Desc; $t3.Foreground = New-Brush '#9D93C4'; $t3.FontSize = 12; $t3.TextWrapping = 'Wrap'
    $t3.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
    [void]$sp.Children.Add($row); [void]$sp.Children.Add($t3)
    return $sp
}

function Build-CleanList {
    foreach ($it in $script:CleanItems) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $window.FindResource('Switch')
        $cb.IsChecked = $it.Def
        $lbl = $null
        $cb.Content = New-SwitchContent $it.Nome $it.Desc ([ref]$lbl)
        $it.CheckBox  = $cb
        $it.SizeLabel = $lbl
        [void]$ui.spClean.Children.Add($cb)
    }
}

# ------------------------------------------------------------------
# 8. Ajustes (Windows, input lag, travadinhas, rede)
# ------------------------------------------------------------------
$CP  = 'HKCU:\Control Panel'
$ADV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$GCS = 'HKCU:\System\GameConfigStore'
$MM  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$MK  = 'HKLM:\SOFTWARE\OptimizerGBZ'
$USB_SUB = '2a737441-1930-4402-8d77-b2bebba308a3'
$USB_SET = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'

function Set-DxSetting([string]$Key, [string]$Val) {
    $p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $cur = [string](Get-Reg $p 'DirectXUserGlobalSettings')
    $parts = @($cur -split ';' | Where-Object { $_ -and ($_ -notmatch "^$Key=") })
    $parts += "$Key=$Val"
    Set-Reg $p 'DirectXUserGlobalSettings' (($parts -join ';') + ';') 'String'
}

function Set-AdapterKeyword([string]$Keyword, [string]$Value) {
    $n = 0
    foreach ($a in Get-ActiveAdapters) {
        $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $Keyword -ErrorAction SilentlyContinue
        if ($p) {
            try { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $Keyword -RegistryValue $Value -ErrorAction Stop; $n++ } catch {}
        }
    }
    return $n
}

function Get-InterfaceKeys {
    return @(Get-ActiveAdapters | ForEach-Object { "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($_.InterfaceGuid)" })
}

# --- Ajustes gerais do Windows ---
$script:WinTweaks = @(
    @{ Nome = 'Efeitos visuais no modo desempenho'
       Desc = 'Desliga animações, sombras e efeitos de janela (o texto continua suave). Vale após sair da conta ou reiniciar.'
       Test = { (Get-Reg "$CP\Desktop\WindowMetrics" 'MinAnimate') -eq '0' }
       Apply = {
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
           Set-Reg "$CP\Desktop" 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
           Set-Reg "$CP\Desktop\WindowMetrics" 'MinAnimate' '0' 'String'
           Set-Reg "$CP\Desktop" 'DragFullWindows' '0' 'String'
           Set-Reg "$CP\Desktop" 'FontSmoothing' '2' 'String'
           Set-Reg $ADV 'TaskbarAnimations' 0
           Set-Reg $ADV 'ListviewAlphaSelect' 0
           Set-Reg $ADV 'ListviewShadow' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0 }
       Revert = {
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 0
           Set-Reg "$CP\Desktop" 'UserPreferencesMask' ([byte[]](0x9E, 0x1E, 0x07, 0x80, 0x12, 0x00, 0x00, 0x00)) 'Binary'
           Set-Reg "$CP\Desktop\WindowMetrics" 'MinAnimate' '1' 'String'
           Set-Reg "$CP\Desktop" 'DragFullWindows' '1' 'String'
           Set-Reg $ADV 'TaskbarAnimations' 1
           Set-Reg $ADV 'ListviewAlphaSelect' 1
           Set-Reg $ADV 'ListviewShadow' 1
           Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 1 } }
    @{ Nome = 'Desativar transparência'
       Desc = 'Tira o efeito de vidro da barra de tarefas e do menu Iniciar. Alivia a placa de vídeo.'
       Test = { (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency') -eq 0 }
       Apply  = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 }
       Revert = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 1 } }
    @{ Nome = 'Desativar sugestões, dicas e anúncios do Windows'
       Desc = 'Tira propagandas do menu Iniciar, dicas na tela de bloqueio e apps instalados sem pedir.'
       Test = { ((Get-Reg $CDM 'SystemPaneSuggestionsEnabled') -eq 0) -and ((Get-Reg $CDM 'SilentInstalledAppsEnabled') -eq 0) }
       Apply  = { foreach ($n in 'SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') { Set-Reg $CDM $n 0 }; Set-Reg $ADV 'ShowSyncProviderNotifications' 0 }
       Revert = { foreach ($n in 'SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') { Set-Reg $CDM $n 1 }; Set-Reg $ADV 'ShowSyncProviderNotifications' 1 } }
    @{ Nome = 'Pesquisa do Iniciar sem resultados da web (Bing)'
       Desc = 'A pesquisa do menu Iniciar procura só no seu PC: fica mais rápida e não abre o navegador.'
       Test = { (Get-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions') -eq 1 }
       Apply  = { Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 }
       Revert = { Remove-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions'; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 1 } }
    @{ Nome = 'Menus abrem sem atraso'
       Desc = 'Os menus do Windows aparecem na hora, sem a espera padrão.'
       Test = { (Get-Reg "$CP\Desktop" 'MenuShowDelay') -eq '0' }
       Apply  = { Set-Reg "$CP\Desktop" 'MenuShowDelay' '0' 'String' }
       Revert = { Set-Reg "$CP\Desktop" 'MenuShowDelay' '400' 'String' } }
)

# --- Input lag ---
$script:InputTweaks = @(
    @{ Nome = 'Desativar aceleração do mouse'
       Desc = 'O ponteiro anda sempre a mesma distância para o mesmo movimento. Essencial para mira consistente.'
       Test = { (Get-Reg "$CP\Mouse" 'MouseSpeed') -eq '0' }
       Apply  = { [void][GabTools]::SetMouseAcceleration($false); Set-Reg "$CP\Mouse" 'MouseSpeed' '0' 'String'; Set-Reg "$CP\Mouse" 'MouseThreshold1' '0' 'String'; Set-Reg "$CP\Mouse" 'MouseThreshold2' '0' 'String' }
       Revert = { [void][GabTools]::SetMouseAcceleration($true);  Set-Reg "$CP\Mouse" 'MouseSpeed' '1' 'String'; Set-Reg "$CP\Mouse" 'MouseThreshold1' '6' 'String'; Set-Reg "$CP\Mouse" 'MouseThreshold2' '10' 'String' } }
    @{ Nome = 'Teclado mais responsivo'
       Desc = 'Menor atraso para a tecla começar a repetir e repetição na velocidade máxima.'
       Test = { (Get-Reg "$CP\Keyboard" 'KeyboardDelay') -eq '0' }
       Apply  = { [GabTools]::SetKeyboard(0, 31); Set-Reg "$CP\Keyboard" 'KeyboardDelay' '0' 'String'; Set-Reg "$CP\Keyboard" 'KeyboardSpeed' '31' 'String' }
       Revert = { [GabTools]::SetKeyboard(1, 31); Set-Reg "$CP\Keyboard" 'KeyboardDelay' '1' 'String'; Set-Reg "$CP\Keyboard" 'KeyboardSpeed' '31' 'String' } }
    @{ Nome = 'Desativar atalho das Teclas de Aderência'
       Desc = 'Acaba com aquela janela que aparece quando você aperta Shift várias vezes no meio do jogo.'
       Test = { (Get-Reg "$CP\Accessibility\StickyKeys" 'Flags') -eq '506' }
       Apply  = { Set-Reg "$CP\Accessibility\StickyKeys" 'Flags' '506' 'String'; Set-Reg "$CP\Accessibility\ToggleKeys" 'Flags' '58' 'String'; Set-Reg "$CP\Accessibility\Keyboard Response" 'Flags' '122' 'String' }
       Revert = { Set-Reg "$CP\Accessibility\StickyKeys" 'Flags' '510' 'String'; Set-Reg "$CP\Accessibility\ToggleKeys" 'Flags' '62' 'String'; Set-Reg "$CP\Accessibility\Keyboard Response" 'Flags' '126' 'String' } }
    @{ Nome = 'Desativar suspensão das portas USB'
       Desc = 'Impede o Windows de "adormecer" as portas USB para economizar energia, o que causa engasgos no mouse e no teclado.'
       Test = { $q = (powercfg /query scheme_current $USB_SUB $USB_SET) -join ' '; $m = [regex]::Matches($q, '0x[0-9a-fA-F]{8}'); ($m.Count -ge 1) -and ($m[0].Value -eq '0x00000000') }
       Apply  = { powercfg /setacvalueindex scheme_current $USB_SUB $USB_SET 0; powercfg /setdcvalueindex scheme_current $USB_SUB $USB_SET 0; powercfg /setactive scheme_current }
       Revert = { powercfg /setacvalueindex scheme_current $USB_SUB $USB_SET 1; powercfg /setdcvalueindex scheme_current $USB_SUB $USB_SET 1; powercfg /setactive scheme_current } }
    @{ Nome = 'Desativar otimizações de tela cheia'
       Desc = 'Faz a tela cheia ser tela cheia de verdade. Costuma reduzir input lag em jogos DirectX 9/11 mais antigos.'
       Test = { (Get-Reg $GCS 'GameDVR_FSEBehaviorMode') -eq 2 }
       Apply  = { Set-Reg $GCS 'GameDVR_FSEBehaviorMode' 2; Set-Reg $GCS 'GameDVR_FSEBehavior' 2; Set-Reg $GCS 'GameDVR_HonorUserFSEBehaviorMode' 1; Set-Reg $GCS 'GameDVR_DXGIHonorFSEWindowsCompatible' 1 }
       Revert = { Set-Reg $GCS 'GameDVR_FSEBehaviorMode' 0; Remove-Reg $GCS 'GameDVR_FSEBehavior'; Set-Reg $GCS 'GameDVR_HonorUserFSEBehaviorMode' 0; Set-Reg $GCS 'GameDVR_DXGIHonorFSEWindowsCompatible' 0 } }
    @{ Nome = 'Agendamento de GPU acelerado por hardware'
       Desc = 'A placa de vídeo organiza o próprio trabalho, com menos atraso. Precisa de GTX 1000 / RX 5000 ou mais nova. Vale após reiniciar.'
       Test = { (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode') -eq 2 }
       Apply  = { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 }
       Revert = { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 1 } }
)

# --- Travadinhas e FPS ---
$script:StutterTweaks = @(
    @{ Nome = 'Modo de Jogo do Windows'
       Desc = 'O Windows dá prioridade ao jogo aberto e segura atualizações e notificações durante a partida.'
       Test = { $v = Get-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'; ($null -eq $v) -or ($v -eq 1) }
       Apply  = { Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1; Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1 }
       Revert = { Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0; Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 0 } }
    @{ Nome = 'Desativar gravação em segundo plano (Game DVR)'
       Desc = 'Para a gravação automática do Xbox que roda escondida e derruba FPS. Causa comum de travadinhas!'
       Test = { (Get-Reg $GCS 'GameDVR_Enabled') -eq 0 }
       Apply  = { Set-Reg $GCS 'GameDVR_Enabled' 0; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 }
       Revert = { Set-Reg $GCS 'GameDVR_Enabled' 1; Remove-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' } }
    @{ Nome = 'Prioridade máxima para jogos'
       Desc = 'O agendador de multimídia do Windows reserva mais processador e placa de vídeo para jogos e menos para tarefas de fundo.'
       Test = { (Get-Reg "$MM\Tasks\Games" 'Priority') -eq 6 }
       Apply  = { Set-Reg "$MM\Tasks\Games" 'GPU Priority' 8; Set-Reg "$MM\Tasks\Games" 'Priority' 6; Set-Reg "$MM\Tasks\Games" 'Scheduling Category' 'High' 'String'; Set-Reg "$MM\Tasks\Games" 'SFIO Priority' 'High' 'String'; Set-Reg $MM 'SystemResponsiveness' 10 }
       Revert = { Set-Reg "$MM\Tasks\Games" 'GPU Priority' 8; Set-Reg "$MM\Tasks\Games" 'Priority' 2; Set-Reg "$MM\Tasks\Games" 'Scheduling Category' 'Medium' 'String'; Set-Reg "$MM\Tasks\Games" 'SFIO Priority' 'Normal' 'String'; Set-Reg $MM 'SystemResponsiveness' 20 } }
    @{ Nome = 'Prioridade para o programa em primeiro plano'
       Desc = 'O processador dá mais atenção à janela que você está usando, no caso, o jogo.'
       Test = { (Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation') -eq 38 }
       Apply  = { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 }
       Revert = { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 2 } }
    @{ Nome = 'Otimizações para jogos em janela'
       Desc = 'No Windows 11, reduz atraso e melhora o frame pacing de jogos em janela ou tela cheia sem bordas.'
       Test = { ([string](Get-Reg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings')) -match 'SwapEffectUpgradeEnable=1' }
       Apply  = { Set-DxSetting 'SwapEffectUpgradeEnable' '1' }
       Revert = { Set-DxSetting 'SwapEffectUpgradeEnable' '0' } }
    @{ Nome = 'Desativar apps em segundo plano'
       Desc = 'Impede que apps da Microsoft Store fiquem rodando escondidos gastando RAM, processador e internet.'
       Test = { (Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled') -eq 1 }
       Apply  = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0 }
       Revert = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0; Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 1 } }
)

# --- Rede ---
$script:NetTweaks = @(
    @{ Nome = 'Desativar algoritmo de Nagle'
       Desc = 'Envia cada pacote na hora em vez de esperar juntar vários. Reduz atraso em jogos que usam TCP (muitos MMOs e alguns online).'
       Test = { $k = Get-InterfaceKeys; ($k.Count -gt 0) -and ((Get-Reg $k[0] 'TCPNoDelay') -eq 1) }
       Apply  = { foreach ($k in Get-InterfaceKeys) { Set-Reg $k 'TcpAckFrequency' 1; Set-Reg $k 'TCPNoDelay' 1 } }
       Revert = { foreach ($k in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue)) { Remove-Reg $k.PSPath 'TcpAckFrequency'; Remove-Reg $k.PSPath 'TCPNoDelay' } } }
    @{ Nome = 'Desativar limitação de rede do Windows'
       Desc = 'O Windows segura o tráfego de rede quando toca áudio ou vídeo. Desligar evita picos de lag com Discord ou música aberta.'
       Test = { $v = Get-Reg $MM 'NetworkThrottlingIndex'; ($v -eq -1) -or ($v -eq 4294967295) }
       Apply  = { Set-Reg $MM 'NetworkThrottlingIndex' (-1) }
       Revert = { Set-Reg $MM 'NetworkThrottlingIndex' 10 } }
    @{ Nome = 'Ajustes de TCP/IP para jogos'
       Desc = 'Ajuste automático de janela no normal, RSS ligado (usa vários núcleos para a rede) e ECN desligado (evita problema com alguns roteadores).'
       Test = { (Get-Reg $MK 'TcpTweak') -eq 1 }
       Apply  = { netsh int tcp set global autotuninglevel=normal | Out-Null; netsh int tcp set global rss=enabled | Out-Null; netsh int tcp set global ecncapability=disabled | Out-Null; netsh int tcp set heuristics disabled | Out-Null; Set-Reg $MK 'TcpTweak' 1 }
       Revert = { netsh int tcp set global ecncapability=default | Out-Null; netsh int tcp set global autotuninglevel=normal | Out-Null; Set-Reg $MK 'TcpTweak' 0 } }
    @{ Nome = 'Desativar economia de energia da placa de rede'
       Desc = 'Impede a placa de rede de entrar em modo econômico (Green Ethernet / EEE), que causa picos de ping. A internet cai por alguns segundos.'
       Test = { (Get-Reg $MK 'NicPower') -eq 1 }
       Apply  = {
           $n = 0
           foreach ($kw in '*EEE', 'EEE', 'EnableGreenEthernet') { $n += Set-AdapterKeyword $kw '0' }
           foreach ($a in Get-ActiveAdapters) { try { Disable-NetAdapterPowerManagement -Name $a.Name -NoRestart -ErrorAction Stop; $n++ } catch {} }
           Set-Reg $MK 'NicPower' 1
           if ($n -eq 0) { Write-Log 'Sua placa de rede não tem essas opções de economia. Nada a mudar.' 'warn' } }
       Revert = {
           foreach ($kw in '*EEE', 'EEE', 'EnableGreenEthernet') { [void](Set-AdapterKeyword $kw '1') }
           foreach ($a in Get-ActiveAdapters) { try { Enable-NetAdapterPowerManagement -Name $a.Name -NoRestart -ErrorAction Stop } catch {} }
           Set-Reg $MK 'NicPower' 0 } }
    @{ Nome = 'Placa de rede em modo baixa latência'
       Desc = 'Desliga a moderação de interrupções: cada pacote é processado na hora. Usa um pouco mais de processador. A internet cai por alguns segundos.'
       Test = { (Get-Reg $MK 'NicIrq') -eq 1 }
       Apply  = { $n = Set-AdapterKeyword '*InterruptModeration' '0'; Set-Reg $MK 'NicIrq' 1; if ($n -eq 0) { Write-Log 'Sua placa de rede não tem essa opção. Nada a mudar.' 'warn' } }
       Revert = { [void](Set-AdapterKeyword '*InterruptModeration' '1'); Set-Reg $MK 'NicIrq' 0 } }
    @{ Nome = 'Windows não envia atualizações para outros PCs'
       Desc = 'Por padrão o Windows usa a sua internet para mandar pedaços de atualização a outras pessoas. Desligar libera o upload.'
       Test = { (Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode') -eq 0 }
       Apply  = { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 }
       Revert = { Remove-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' } }
)

$script:LoadingTweaks = $false
$tweakHandler = {
    param($src, $e)
    if ($script:LoadingTweaks) { return }
    $t  = $src.Tag
    $on = [bool]$src.IsChecked
    Set-Status "Aplicando ajuste..." $true
    try {
        if ($on) { & $t.Apply; Write-Log "Ativado: $($t.Nome)" 'ok' }
        else     { & $t.Revert; Write-Log "Desfeito: $($t.Nome)" 'ok' }
    } catch {
        Write-Log "$($t.Nome): $($_.Exception.Message)" 'err'
    } finally {
        Set-Status 'Pronto' $false
    }
}

function Build-TweakList($Panel, $Tweaks) {
    $script:LoadingTweaks = $true
    foreach ($t in $Tweaks) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $window.FindResource('Switch')
        $cb.Tag = $t
        $cb.Content = New-SwitchContent $t.Nome $t.Desc $null
        try { $cb.IsChecked = [bool](& $t.Test) } catch { $cb.IsChecked = $false }
        $cb.Add_Checked($tweakHandler)
        $cb.Add_Unchecked($tweakHandler)
        [void]$Panel.Children.Add($cb)
    }
    $script:LoadingTweaks = $false
}

# ------------------------------------------------------------------
# 9. Energia e Modo Gamer
# ------------------------------------------------------------------
$script:PlanGuids = @{
    balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    high     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
}

function Get-ActivePlanGuid {
    $out = (powercfg /getactivescheme) -join ' '
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { return $Matches[1].ToLower() }
    return ''
}

function Update-PowerPlanText {
    $out  = (powercfg /getactivescheme) -join ' '
    $name = if ($out -match '\(([^)]+)\)') { $Matches[1] } else { $out }
    $ui.txtPowerPlan.Text = "Plano ativo: $name"
}

function Set-PowerPlan([string]$Kind) {
    $guid = $script:PlanGuids[$Kind]
    powercfg /setactive $guid 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        powercfg /duplicatescheme $guid $guid 2>$null | Out-Null
        powercfg /setactive $guid 2>$null | Out-Null
    }
    if ($LASTEXITCODE -eq 0) {
        Update-PowerPlanText
        Write-Log "Plano de energia alterado. $($ui.txtPowerPlan.Text)" 'ok'
        return $true
    }
    Write-Log 'Este PC não permite esse plano de energia (comum em alguns notebooks).' 'warn'
    return $false
}

function Update-GamerState([bool]$On) {
    $script:GamerOn = $On
    if ($On) {
        $ui.txtGamerState.Text = 'ATIVO'
        $ui.txtGamerState.Foreground = New-Brush '#0B0716'
        $ui.badgeGamer.Background = New-Brush '#39FF88'
        $ui.txtHeroTitle.Text = 'Modo Gamer ativo'
        $ui.txtGamerSide.Text = 'ATIVADO'
        $ui.dotGamer.Fill = New-Brush '#39FF88'
        Start-Pulse $ui.dotGamer
    } else {
        $ui.txtGamerState.Text = 'DESLIGADO'
        $ui.txtGamerState.Foreground = New-Brush '#FFFFFF'
        $ui.badgeGamer.Background = New-Brush '#40FFFFFF'
        $ui.txtHeroTitle.Text = 'Ative o Modo Gamer'
        $ui.txtGamerSide.Text = 'DESLIGADO'
        $ui.dotGamer.Fill = New-Brush '#4A3F70'
        Stop-Pulse $ui.dotGamer
    }
}

function Enable-GamerMode {
    Write-Log '=== MODO GAMER: ativando ==='
    if (-not (Set-PowerPlan 'ultimate')) { [void](Set-PowerPlan 'high') }
    Stop-Service wuauserv, bits, DoSvc -Force -ErrorAction SilentlyContinue
    Write-Log 'Downloads do Windows Update em segundo plano pausados até reiniciar o PC.' 'ok'
    Clear-Dns
    [void](Invoke-FreeRam)
    Update-GamerState $true
    Update-DiscordPresence
    if (((Get-Reg $script:ColorRegPath 'RgbGamer') -eq 1) -and $script:RgbExe) { Invoke-RgbApply }
    Write-Log '=== MODO GAMER ATIVADO. Bom jogo! ===' 'ok'
}

function Disable-GamerMode {
    Write-Log 'Voltando ao normal...'
    [void](Set-PowerPlan 'balanced')
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue
    Update-GamerState $false
    Update-DiscordPresence
    Write-Log 'Modo Gamer desligado. Plano Equilibrado e Windows Update de volta.' 'ok'
}

# ------------------------------------------------------------------
# 10. Internet: teste de lag, DNS, quem usa a rede
# ------------------------------------------------------------------
function Clear-Dns {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    ipconfig /flushdns | Out-Null
    Write-Log 'Cache de DNS limpo.' 'ok'
}

function Test-PingTarget([string]$Target, [int]$Count = 20) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object System.Collections.Generic.List[double]
    $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $p.Send($Target, 1000)
            if ($r.Status -eq 'Success') { $times.Add([double]$r.RoundtripTime) } else { $lost++ }
        } catch { $lost++ }
        Update-UI
        Start-Sleep -Milliseconds 80
    }
    $p.Dispose()
    if ($times.Count -eq 0) { return @{ Avg = -1; Jitter = 0; Loss = 100 } }
    $avg = ($times | Measure-Object -Average).Average
    $jit = 0
    if ($times.Count -gt 1) {
        $diffs = for ($i = 1; $i -lt $times.Count; $i++) { [math]::Abs($times[$i] - $times[$i - 1]) }
        $jit = ($diffs | Measure-Object -Average).Average
    }
    return @{ Avg = $avg; Jitter = $jit; Loss = [math]::Round($lost * 100 / $Count) }
}

function Invoke-PingTest {
    $ui.spPing.Children.Clear()
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    $targets = @()
    if ($gw -and $gw -ne '0.0.0.0') { $targets += @{ Nome = "Seu roteador ($gw)"; Ip = $gw; Local = $true } }
    $targets += @{ Nome = 'Internet: Cloudflare (1.1.1.1)'; Ip = '1.1.1.1'; Local = $false }
    $targets += @{ Nome = 'Internet: Google (8.8.8.8)'; Ip = '8.8.8.8'; Local = $false }

    $localBad = $false; $netBad = $false; $i = 0
    foreach ($t in $targets) {
        Write-Log "Testando $($t.Nome) (20 pings)..."
        $r = Test-PingTarget $t.Ip 20
        if ($r.Avg -lt 0) {
            $level = 'bad'; $right = 'SEM RESPOSTA'
            if ($t.Local) { $localBad = $true } else { $netBad = $true }
        } else {
            $right = '{0:N0} ms  |  jitter {1:N0} ms  |  perda {2}%' -f $r.Avg, $r.Jitter, $r.Loss
            if ($t.Local) {
                $level = if ($r.Loss -gt 0 -or $r.Avg -gt 10 -or $r.Jitter -gt 5) { 'bad' } elseif ($r.Avg -gt 4) { 'warn' } else { 'ok' }
                if ($level -eq 'bad') { $localBad = $true }
            } else {
                $level = if ($r.Loss -gt 2 -or $r.Avg -gt 100 -or $r.Jitter -gt 25) { 'bad' } elseif ($r.Avg -gt 50 -or $r.Jitter -gt 10 -or $r.Loss -gt 0) { 'warn' } else { 'ok' }
                if ($level -eq 'bad') { $netBad = $true }
            }
        }
        [void]$ui.spPing.Children.Add((New-ResultRow $level $t.Nome $right $i))
        $i++
        Write-Log "$($t.Nome): $right" $(if ($level -eq 'ok') { 'ok' } else { 'warn' })
    }
    if ($localBad) {
        $msg = 'O problema está entre o PC e o roteador (Wi-Fi fraco, interferência ou cabo ruim). Use cabo ou aproxime o PC do roteador.'
        $lvl = 'bad'
    } elseif ($netBad) {
        $msg = 'Sua rede de casa está boa, o lag vem do provedor ou da rota até a internet. Reinicie o modem; se continuar, fale com o provedor.'
        $lvl = 'bad'
    } else {
        $msg = 'Conexão estável! Se ainda tem lag num jogo, o problema pode ser o servidor do jogo ou a região escolhida.'
        $lvl = 'ok'
    }
    [void]$ui.spPing.Children.Add((New-ResultRow $lvl $msg '' $i))
    Write-Log $msg
}

$script:DnsProviders = @(
    @{ Nome = 'Cloudflare'; Ips = @('1.1.1.1', '1.0.0.1') }
    @{ Nome = 'Google';     Ips = @('8.8.8.8', '8.8.4.4') }
    @{ Nome = 'Quad9';      Ips = @('9.9.9.9', '149.112.112.112') }
    @{ Nome = 'OpenDNS';    Ips = @('208.67.222.222', '208.67.220.220') }
)
$script:BestDns = $null

function Measure-Dns([string]$Server) {
    $domains = 'google.com', 'youtube.com', 'microsoft.com', 'amazon.com', 'wikipedia.org', 'steampowered.com', 'riotgames.com', 'epicgames.com'
    $times = @()
    foreach ($d in $domains) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            Resolve-DnsName -Name $d -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Out-Null
            $sw.Stop(); $times += $sw.Elapsed.TotalMilliseconds
        } catch {}
        Update-UI
    }
    if ($times.Count -lt ($domains.Count / 2)) { return -1 }
    return ($times | Measure-Object -Average).Average
}

function Invoke-DnsTest {
    $ui.spDns.Children.Clear()
    $ui.btnDnsBest.IsEnabled = $false
    $results = @()
    $ad = Get-ActiveAdapters | Select-Object -First 1
    if ($ad) {
        $cur = (Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Select-Object -First 1
        if ($cur -and -not ($script:DnsProviders | Where-Object { $_.Ips -contains $cur })) {
            Write-Log "Testando seu DNS atual ($cur)..."
            $results += [pscustomobject]@{ Nome = "Seu DNS atual ($cur)"; Ms = (Measure-Dns $cur); Prov = $null }
        }
    }
    foreach ($p in $script:DnsProviders) {
        Write-Log "Testando DNS $($p.Nome)..."
        $results += [pscustomobject]@{ Nome = "$($p.Nome) ($($p.Ips[0]))"; Ms = (Measure-Dns $p.Ips[0]); Prov = $p }
    }
    $ok = @($results | Where-Object { $_.Ms -ge 0 } | Sort-Object Ms)
    $i = 0
    foreach ($r in $ok) {
        $level = if ($i -eq 0) { 'ok' } elseif ($r.Ms -lt ($ok[0].Ms * 1.5)) { 'info' } else { 'warn' }
        $label = if ($i -eq 0) { "1º  $($r.Nome)" } else { "$($i + 1)º  $($r.Nome)" }
        [void]$ui.spDns.Children.Add((New-ResultRow $level $label ('{0:N0} ms' -f $r.Ms) $i))
        $i++
    }
    foreach ($r in @($results | Where-Object { $_.Ms -lt 0 })) {
        [void]$ui.spDns.Children.Add((New-ResultRow 'bad' $r.Nome 'falhou' $i)); $i++
    }
    if ($ok.Count -eq 0) { Write-Log 'Nenhum DNS respondeu. Verifique a conexão.' 'err'; return }
    if ($ok[0].Prov) {
        $script:BestDns = $ok[0].Prov
        $ui.btnDnsBest.IsEnabled = $true
        $ui.btnDnsBest.Content = "USAR $($ok[0].Prov.Nome.ToUpper())"
        Write-Log "Mais rápido: $($ok[0].Nome) com $('{0:N0}' -f $ok[0].Ms) ms." 'ok'
    } else {
        $script:BestDns = $null
        Write-Log 'Seu DNS atual já é o mais rápido. Não precisa trocar!' 'ok'
        [void]$ui.spDns.Children.Add((New-ResultRow 'ok' 'Seu DNS atual já é o mais rápido. Não precisa trocar!' '' $i))
    }
}

function Set-DnsAll($Ips) {
    foreach ($a in Get-ActiveAdapters) {
        if ($Ips) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $Ips -ErrorAction Stop }
        else      { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Show-NetUsers {
    Write-Log 'Programas com conexões abertas na internet agora:'
    $groups = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
              Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0)' } |
              Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 12
    foreach ($g in $groups) {
        $p = Get-Process -Id ([int]$g.Name) -ErrorAction SilentlyContinue
        $n = if ($p) { $p.ProcessName } else { "PID $($g.Name)" }
        Write-Log ("  {0,-28} {1} conexões" -f $n, $g.Count)
    }
    Write-Log 'Dica: Steam, Epic, OneDrive, Google Drive e navegadores baixando coisas em segundo plano são os vilões mais comuns de lag.'
}

# ------------------------------------------------------------------
# 11. Diagnóstico de travadinhas
# ------------------------------------------------------------------
function Invoke-Diagnosis {
    $ui.spDiag.Children.Clear()
    $ui.cardDiag.Visibility = 'Visible'
    $res = New-Object System.Collections.ArrayList
    function Add-R($lvl, $txt) { [void]$res.Add(@{ L = $lvl; T = $txt }) }
    Write-Log 'Escaneando o PC...'

    # RAM
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $ramGB = $cs.TotalPhysicalMemory / 1GB
    $usedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100)
    if ($usedPct -ge 85) { Add-R 'bad' "RAM quase cheia ($usedPct% em uso). Quando acaba, o Windows usa o disco e o jogo trava. Feche programas ou use Liberar RAM." }
    elseif ($usedPct -ge 70) { Add-R 'warn' "RAM com uso alto ($usedPct%). Feche o que não precisa antes de jogar." }
    else { Add-R 'ok' "RAM com folga ($usedPct% em uso)." }
    if ($ramGB -lt 7.5) { Add-R 'bad' ('Só {0:N0} GB de RAM. Jogos atuais pedem 16 GB; com 8 GB ou menos, travadinhas são normais. Upgrade de RAM resolve muito.' -f $ramGB) }
    elseif ($ramGB -lt 15) { Add-R 'warn' ('{0:N0} GB de RAM: dá para jogar, mas 16 GB deixam tudo mais liso.' -f $ramGB) }
    Update-UI

    # Arquivo de paginação
    if (-not (Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) {
        Add-R 'bad' 'Arquivo de paginação (memória virtual) desativado! Isso causa travadas e jogos fechando. Reative em Configurações avançadas do sistema.'
    }

    # Disco
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $freePct = [math]::Round($d.FreeSpace / $d.Size * 100)
    if ($freePct -lt 10) { Add-R 'bad' "Disco $($env:SystemDrive) quase cheio ($freePct% livre). Use a aba Limpeza." }
    elseif ($freePct -lt 15) { Add-R 'warn' "Disco $($env:SystemDrive) com pouco espaço ($freePct% livre)." }
    else { Add-R 'ok' "Espaço em disco ok ($freePct% livre)." }
    try {
        $dn = (Get-Partition -DriveLetter $env:SystemDrive[0] -ErrorAction Stop).DiskNumber
        $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.DeviceId)" -eq "$dn" } | Select-Object -First 1
        if ($pd -and "$($pd.MediaType)" -eq 'HDD') { Add-R 'bad' 'O Windows está num HD comum. É a maior causa de lentidão e travadas ao carregar. Um SSD muda o PC da água pro vinho.' }
        elseif ($pd -and "$($pd.MediaType)" -eq 'SSD') { Add-R 'ok' 'Windows instalado em SSD.' }
    } catch {}
    try {
        $busy = (Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop).PercentDiskTime
        if ($busy -ge 90) { Add-R 'bad' "Disco trabalhando no limite agora ($busy%). Algum programa está lendo/gravando muito." }
    } catch {}
    Update-UI

    # Energia
    $g = Get-ActivePlanGuid
    if ($g -eq $script:PlanGuids.ultimate -or $g -eq $script:PlanGuids.high) { Add-R 'ok' 'Plano de energia em alto desempenho.' }
    else { Add-R 'warn' 'Plano de energia não está no máximo. O processador economiza energia e demora para acelerar. Ative o Modo Gamer.' }

    # Game DVR, Modo de Jogo, HAGS
    if ((Get-Reg $GCS 'GameDVR_Enabled') -ne 0) { Add-R 'warn' 'Gravação em segundo plano do Xbox (Game DVR) está ligada. Desligue em "Menos travadinhas".' }
    else { Add-R 'ok' 'Game DVR desligado.' }
    $gm = Get-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    if ($gm -eq 0) { Add-R 'warn' 'Modo de Jogo do Windows está desligado.' }
    if ((Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode') -ne 2) { Add-R 'info' 'Agendamento de GPU por hardware está desligado. Se sua placa for GTX 1000 / RX 5000 ou mais nova, vale testar ligado.' }
    Update-UI

    # Driver de vídeo
    foreach ($vc in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        if ($vc.Name -match 'Basic Display|Básico|VGA') { Add-R 'bad' "Driver de vídeo não instalado ($($vc.Name)). Instale o driver da sua placa: é obrigatório para jogar." }
        elseif ($vc.DriverDate -and ((Get-Date) - $vc.DriverDate).TotalDays -gt 365) { Add-R 'warn' "Driver de vídeo antigo ($($vc.Name), de $($vc.DriverDate.ToString('MM/yyyy'))). Atualize pelo site da NVIDIA, AMD ou Intel." }
        elseif ($vc.DriverDate) { Add-R 'ok' "Driver de vídeo recente ($($vc.Name))." }
    }

    # Tempo ligado
    $up = (Get-Date) - $os.LastBootUpTime
    if ($up.TotalDays -ge 3) { Add-R 'warn' ('PC ligado há {0:N0} dias sem reiniciar. Reiniciar limpa memória e processos travados.' -f [math]::Floor($up.TotalDays)) }

    # Programas pesados em segundo plano
    Write-Log 'Medindo uso de processador em segundo plano...'
    $cores = [Environment]::ProcessorCount
    $s1 = @{}
    foreach ($p in Get-Process) { try { $s1[$p.Id] = $p.TotalProcessorTime.TotalSeconds } catch {} }
    for ($k = 0; $k -lt 15; $k++) { Start-Sleep -Milliseconds 100; Update-UI }
    $heavy = @(foreach ($p in Get-Process) {
        if ($s1.ContainsKey($p.Id) -and $p.Id -ne $PID -and $p.ProcessName -ne 'Idle') {
            try {
                $pct = ($p.TotalProcessorTime.TotalSeconds - $s1[$p.Id]) / 1.5 / $cores * 100
                if ($pct -ge 8) { [pscustomobject]@{ N = $p.ProcessName; P = $pct } }
            } catch {}
        }
    }) | Sort-Object P -Descending | Select-Object -First 4
    if ($heavy.Count -gt 0) {
        $list = ($heavy | ForEach-Object { '{0} ({1:N0}%)' -f $_.N, $_.P }) -join ', '
        Add-R 'warn' "Programas usando muito processador agora: $list. Feche antes de jogar se não precisar."
    } else { Add-R 'ok' 'Nenhum programa pesado rodando em segundo plano.' }

    # Inicialização
    try {
        $enabled = @(Get-StartupItems | Where-Object { $_.Status -eq 'Ativado' }).Count
        if ($enabled -gt 8) { Add-R 'warn' "$enabled programas abrem junto com o Windows e ficam rodando. Desative os desnecessários na aba Inicialização." }
        else { Add-R 'ok' "Poucos programas na inicialização ($enabled)." }
    } catch {}

    # Conexão
    $ad = Get-ActiveAdapters
    if (-not ($ad | Where-Object { "$($_.PhysicalMediaType)" -match '802\.3' }) -and ($ad | Where-Object { "$($_.PhysicalMediaType)" -match '802\.11' })) {
        Add-R 'warn' 'Você está no Wi-Fi. Wi-Fi oscila e causa picos de ping; cabo de rede é o que mais reduz lag online.'
    }

    # Integridade de memória (VBS)
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($dg.SecurityServicesRunning -contains 2) {
            Add-R 'info' 'Integridade de memória (Isolamento de núcleo) está ligada. Protege contra vírus, mas pode custar alguns FPS. Desligar é escolha sua, em Segurança do Windows > Segurança do dispositivo.'
        }
    } catch {}

    # Pontuação
    $bad  = @($res | Where-Object { $_.L -eq 'bad' }).Count
    $warn = @($res | Where-Object { $_.L -eq 'warn' }).Count
    $score = [math]::Max(0, 100 - $bad * 15 - $warn * 6)
    Set-CountText $ui.txtScore $score ''
    Set-Gauge $ui.gScore $score
    $ui.txtScoreSub.Text = if ($score -ge 85) { 'Seu PC está bem configurado! Veja os detalhes abaixo.' }
                           elseif ($score -ge 60) { "Achei $($bad + $warn) coisas para melhorar. Veja abaixo, do mais grave para o mais leve." }
                           else { "Achei $($bad + $warn) problemas que podem estar causando as travadinhas. Comece pelos vermelhos." }
    $order = @{ bad = 0; warn = 1; info = 2; ok = 3 }
    $i = 0
    foreach ($r in ($res | Sort-Object { $order[$_.L] })) {
        [void]$ui.spDiag.Children.Add((New-ResultRow $r.L $r.T '' $i)); $i++
    }
    Write-Log "Diagnóstico concluído: $score/100 ($bad graves, $warn avisos)." 'ok'
}

# ------------------------------------------------------------------
# 11b. Tela e cores
# ------------------------------------------------------------------
$script:ColorKeys = 'B', 'C', 'G', 'K', 'S'
$script:Color = @{ B = 1.0; C = 1.0; G = 1.0; K = 6500.0; S = 1.0 }
$script:ColorProfiles = [ordered]@{
    'Padrão'         = @{ Icon = 0xE7F4; Cor = '#B9B0DA'; Desc = 'Cores originais do monitor.'; B = 1.0; C = 1.0; G = 1.0; K = 6500.0; S = 1.0 }
    'Gamer vibrante' = @{ Icon = 0xE7FC; Cor = '#E879F9'; Desc = 'Cores fortes e vivas, estilo vibração digital. Ótimo para jogos coloridos.'; B = 1.0; C = 1.06; G = 1.0; K = 6800.0; S = 1.4 }
    'Competitivo'    = @{ Icon = 0xE890; Cor = '#39FF88'; Desc = 'Clareia as sombras e destaca as cores: inimigos no escuro aparecem mais.'; B = 1.0; C = 1.0; G = 1.35; K = 6600.0; S = 1.3 }
    'Filme'          = @{ Icon = 0xE8B2; Cor = '#FACC15'; Desc = 'Mais contraste e um tom levemente quente, como no cinema.'; B = 0.96; C = 1.1; G = 0.95; K = 6000.0; S = 1.1 }
    'Noite'          = @{ Icon = 0xE708; Cor = '#FB923C'; Desc = 'Menos luz azul: cansa menos a vista e atrapalha menos o sono.'; B = 0.92; C = 1.0; G = 1.0; K = 4200.0; S = 0.95 }
    'Leitura'        = @{ Icon = 0xE736; Cor = '#60A5FA'; Desc = 'Tons suaves e menos saturados para ler e estudar por horas.'; B = 0.95; C = 0.95; G = 1.0; K = 5500.0; S = 0.8 }
}
$script:SliderDefs = @(
    @{ Key = 'B'; Nome = 'Brilho';         Min = 50;   Max = 150;  Scale = 100; Fmt = { param($v) '{0:N0}%' -f $v } }
    @{ Key = 'C'; Nome = 'Contraste';      Min = 50;   Max = 150;  Scale = 100; Fmt = { param($v) '{0:N0}%' -f $v } }
    @{ Key = 'G'; Nome = 'Gama (sombras)'; Min = 50;   Max = 200;  Scale = 100; Fmt = { param($v) '{0:N2}' -f ($v / 100) } }
    @{ Key = 'K'; Nome = 'Temperatura';    Min = 3000; Max = 9000; Scale = 1;   Fmt = { param($v) '{0:N0} K' -f $v } }
    @{ Key = 'S'; Nome = 'Saturação';      Min = 0;    Max = 200;  Scale = 100; Fmt = { param($v) '{0:N0}%' -f $v } }
)
$script:ColorRegPath = 'HKCU:\Software\OptimizerGBZ'
$script:ActiveProfile = 'Padrão'

# Temperatura de cor (Kelvin) para multiplicadores de vermelho, verde e azul
function Get-TempMultipliers([double]$Kelvin) {
    function Get-Rgb([double]$K) {
        $t = $K / 100
        if ($t -le 66) { $r = 255 } else { $r = 329.698727446 * [math]::Pow($t - 60, -0.1332047592) }
        if ($t -le 66) { $g = 99.4708025861 * [math]::Log($t) - 161.1195681661 } else { $g = 288.1221695283 * [math]::Pow($t - 60, -0.0755148492) }
        if ($t -ge 66) { $b = 255 } elseif ($t -le 19) { $b = 0 } else { $b = 138.5177312231 * [math]::Log($t - 10) - 305.0447927307 }
        return @(([math]::Max(0, [math]::Min(255, $r))), ([math]::Max(0, [math]::Min(255, $g))), ([math]::Max(1, [math]::Min(255, $b))))
    }
    $ref = Get-Rgb 6500
    $cur = Get-Rgb $Kelvin
    $m = @(($cur[0] / $ref[0]), ($cur[1] / $ref[1]), ($cur[2] / $ref[2]))
    $max = ($m | Measure-Object -Maximum).Maximum
    return @(($m[0] / $max), ($m[1] / $max), ($m[2] / $max))
}

function Invoke-ColorApply($c) {
    if (-not $script:GammaRangeChecked) {
        $script:GammaRangeChecked = $true
        # Libera ajustes de cor mais fortes (o Windows limita por padrão)
        if ((Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM' 'GdiIcmGammaRange') -ne 256) {
            try { Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM' 'GdiIcmGammaRange' 256 } catch {}
            $script:GammaNeedsReboot = $true
        }
    }
    $m = Get-TempMultipliers ([double]$c.K)
    $n = [GabColor]::ApplyGamma([double]$c.B, [double]$c.C, [double]$c.G, $m[0], $m[1], $m[2])
    if ($n -eq 0 -and -not $script:GammaWarned) {
        $script:GammaWarned = $true
        if ($script:GammaNeedsReboot) { Write-Log 'O Windows recusou parte do ajuste de cor. Reinicie o PC uma vez para liberar ajustes mais fortes.' 'warn' }
        else { Write-Log 'O Windows recusou o ajuste de cor. Isso acontece com HDR ou Luz noturna ligados: desligue-os e tente de novo.' 'warn' }
    }
    if ([math]::Abs([double]$c.S - 1) -lt 0.02) {
        [GabColor]::ResetSaturation()
    } else {
        $ok = [GabColor]::SetSaturation([double]$c.S)
        if (-not $ok -and -not $script:SatWarned) { $script:SatWarned = $true; Write-Log 'O Windows não aceitou o ajuste de saturação neste PC.' 'warn' }
    }
}

function Set-ProfileName([string]$Name, [string]$Desc) {
    $script:ActiveProfile = $Name
    $ui.txtColorProfile.Text = $Name
    $ui.txtColorDesc.Text = $Desc
    foreach ($b in $ui.ugProfiles.Children) {
        if ($b.Tag -eq $Name) { $b.BorderBrush = New-Brush '#D946EF'; $b.Background = New-Brush '#3B1F6E' }
        else { $b.BorderBrush = New-Brush '#33295A'; $b.Background = New-Brush '#241B40' }
    }
}

function Sync-Sliders {
    $script:SyncingSliders = $true
    foreach ($d in $script:SliderDefs) { $d.Slider.Value = [double]$script:Color[$d.Key] * $d.Scale; $d.Label.Text = & $d.Fmt $d.Slider.Value }
    $script:SyncingSliders = $false
}

function Save-Color {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    Set-Reg $script:ColorRegPath 'ColorProfile' $script:ActiveProfile 'String'
    foreach ($k in $script:ColorKeys) { Set-Reg $script:ColorRegPath "Color$k" (([double]$script:Color[$k]).ToString($inv)) 'String' }
}

# Transição suave entre modos (a tela "desliza" até as cores novas)
function Set-ColorSmooth($Target, [string]$Name, [string]$Desc) {
    if ($script:ColorAnim) { $script:ColorAnim.Stop() }
    $script:ColorFrom = $script:Color.Clone()
    $script:ColorTo = @{}
    foreach ($k in $script:ColorKeys) { $script:ColorTo[$k] = [double]$Target[$k] }
    $script:ColorStep = 0
    Set-ProfileName $Name $Desc
    $script:ColorAnim = New-Object System.Windows.Threading.DispatcherTimer
    $script:ColorAnim.Interval = [TimeSpan]::FromMilliseconds(30)
    $script:ColorAnim.Add_Tick({
        $script:ColorStep++
        $t = [math]::Min(1, $script:ColorStep / 14)
        $ease = 1 - [math]::Pow(1 - $t, 3)
        $c = @{}
        foreach ($k in $script:ColorKeys) { $c[$k] = $script:ColorFrom[$k] + ($script:ColorTo[$k] - $script:ColorFrom[$k]) * $ease }
        try { Invoke-ColorApply $c } catch {}
        if ($t -ge 1) {
            $script:ColorAnim.Stop()
            $script:Color = $c
            Sync-Sliders
            Save-Color
        }
    })
    $script:ColorAnim.Start()
}

$sliderHandler = {
    param($src, $e)
    $d = $src.Tag
    $d.Label.Text = & $d.Fmt $src.Value
    if ($script:SyncingSliders) { return }
    $script:Color[$d.Key] = $src.Value / $d.Scale
    try { Invoke-ColorApply $script:Color } catch {}
    if ($script:ActiveProfile -ne 'Personalizado') { Set-ProfileName 'Personalizado' 'Seu ajuste próprio, feito nos controles abaixo.' }
    $script:ColorDirty = $true
}

function Build-ColorPage {
    foreach ($name in $script:ColorProfiles.Keys) {
        $p = $script:ColorProfiles[$name]
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $window.FindResource('ProfileCard')
        $b.Tag = $name
        $sp = New-Object System.Windows.Controls.StackPanel
        $ic = New-Object System.Windows.Controls.TextBlock
        $ic.Text = [string][char]$p.Icon; $ic.FontFamily = 'Segoe MDL2 Assets'; $ic.FontSize = 24; $ic.Foreground = New-Brush $p.Cor
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $name; $nm.FontWeight = 'Black'; $nm.FontSize = 15; $nm.Margin = New-Object System.Windows.Thickness 0, 8, 0, 2
        $ds = New-Object System.Windows.Controls.TextBlock
        $ds.Text = $p.Desc; $ds.TextWrapping = 'Wrap'; $ds.FontSize = 11.5; $ds.FontWeight = 'Normal'; $ds.Foreground = New-Brush '#9D93C4'
        [void]$sp.Children.Add($ic); [void]$sp.Children.Add($nm); [void]$sp.Children.Add($ds)
        $b.Content = $sp
        $b.Add_Click({
            param($s, $e)
            $n = $s.Tag
            $pp = $script:ColorProfiles[$n]
            Set-ColorSmooth $pp $n $pp.Desc
            Write-Log "Modo de cor: $n" 'ok'
        })
        [void]$ui.ugProfiles.Children.Add($b)
    }

    foreach ($d in $script:SliderDefs) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14
        foreach ($w in '150', '*', '80') {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
            [void]$g.ColumnDefinitions.Add($cd)
        }
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = $d.Nome; $lb.FontWeight = 'SemiBold'; $lb.FontSize = 13; $lb.VerticalAlignment = 'Center'
        $sl = New-Object System.Windows.Controls.Slider
        $sl.Style = $window.FindResource('NeonSlider')
        $sl.Minimum = $d.Min; $sl.Maximum = $d.Max
        if ($d.Key -eq 'K') { $sl.SmallChange = 100; $sl.LargeChange = 500 } else { $sl.SmallChange = 1; $sl.LargeChange = 10 }
        $sl.Tag = $d
        [System.Windows.Controls.Grid]::SetColumn($sl, 1)
        $vl = New-Object System.Windows.Controls.TextBlock
        $vl.FontWeight = 'Black'; $vl.Foreground = New-Brush '#E879F9'; $vl.HorizontalAlignment = 'Right'; $vl.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($vl, 2)
        [void]$g.Children.Add($lb); [void]$g.Children.Add($sl); [void]$g.Children.Add($vl)
        $d.Slider = $sl; $d.Label = $vl
        $sl.Add_ValueChanged($sliderHandler)
        [void]$ui.spSliders.Children.Add($g)
    }

    # Botões do programa da placa de vídeo
    $gpus = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ' '
    $apps = @()
    if ($gpus -match 'NVIDIA') { $apps += @{ T = 'Abrir NVIDIA (Vibração digital)'; V = 'nvidia' } }
    if ($gpus -match 'AMD|Radeon') { $apps += @{ T = 'Abrir AMD Software (Saturação)'; V = 'amd' } }
    if ($gpus -match 'Intel') { $apps += @{ T = 'Abrir Intel Graphics (Saturação)'; V = 'intel' } }
    $apps += @{ T = 'Calibrar cores do monitor (Windows)'; V = 'dccw' }
    foreach ($a in $apps) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $a.T; $b.Tag = $a.V
        if ($a.V -ne 'dccw') { $b.Style = $window.FindResource('Primary') }
        $b.Add_Click({ param($s, $e) Open-GpuApp $s.Tag })
        [void]$ui.wpGpuApps.Children.Add($b)
    }
}

function Open-GpuApp([string]$Vendor) {
    $exe = @(); $shell = @()
    switch ($Vendor) {
        'nvidia' {
            $exe = @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe", "$env:ProgramFiles\NVIDIA Corporation\Control Panel Client\nvcplui.exe")
            $shell = @('shell:AppsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel')
        }
        'amd'   { $exe = @("$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe") }
        'intel' { $shell = @('shell:AppsFolder\AppUp.IntelGraphicsExperience_8j3eq9eme6ctt!App') }
        'dccw'  { Start-Process dccw.exe; return }
    }
    foreach ($e in $exe) { if (Test-Path -LiteralPath $e) { Start-Process -FilePath $e; Write-Log "Abrindo $([IO.Path]::GetFileNameWithoutExtension($e))..."; return } }
    foreach ($sh in $shell) { try { Start-Process explorer.exe -ArgumentList $sh; Write-Log 'Abrindo o programa da placa de vídeo...'; return } catch {} }
    Write-Log 'Não encontrei o programa da placa de vídeo. Instale o driver mais recente pelo site do fabricante.' 'warn'
}

function Restore-SavedColor {
    $name = Get-Reg $script:ColorRegPath 'ColorProfile'
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $c = @{}
    $isDefault = $true
    foreach ($k in $script:ColorKeys) {
        $v = Get-Reg $script:ColorRegPath "Color$k"
        if ($v) { $c[$k] = [double]::Parse([string]$v, $inv) } else { $c[$k] = [double]$script:ColorProfiles['Padrão'][$k] }
        if ([math]::Abs($c[$k] - [double]$script:ColorProfiles['Padrão'][$k]) -gt 0.001) { $isDefault = $false }
    }
    if (-not $name -or $isDefault) { Sync-Sliders; Set-ProfileName 'Padrão' $script:ColorProfiles['Padrão'].Desc; return }
    $desc = if ($script:ColorProfiles.Contains($name)) { $script:ColorProfiles[$name].Desc } else { 'Seu ajuste próprio, feito nos controles abaixo.' }
    Set-ColorSmooth $c $name $desc
    Write-Log "Modo de cor '$name' reaplicado." 'ok'
}

# ------------------------------------------------------------------
# 11c. Iluminação RGB (usa o OpenRGB por baixo, pela linha de comando)
# ------------------------------------------------------------------
$script:Rgb = @{ Hex = 'A855F7'; Mode = 'static'; Bright = 100 }
$script:RgbModes = [ordered]@{ 'Estático' = 'static'; 'Respirar' = 'breathing'; 'Arco-íris' = 'rainbow'; 'Desligar' = 'off' }
$script:RgbSwatches = 'A855F7', 'D946EF', 'EC4899', 'FF1E3C', 'FF7A00', 'FACC15', '39FF88', '00E5FF', '3B82F6', 'FFFFFF'
$script:RgbScenes = @(
    @{ N = 'Roxo neon';       Hex = 'A855F7'; M = 'static' }
    @{ N = 'Vermelho gamer';  Hex = 'FF1E3C'; M = 'static' }
    @{ N = 'Azul gelo';       Hex = '38BDF8'; M = 'static' }
    @{ N = 'Verde Matrix';    Hex = '39FF88'; M = 'static' }
    @{ N = 'Branco';          Hex = 'FFFFFF'; M = 'static' }
    @{ N = 'Respiração rosa'; Hex = 'D946EF'; M = 'breathing' }
    @{ N = 'Arco-íris';       Hex = 'FF0000'; M = 'rainbow' }
    @{ N = 'Desligar LEDs';   Hex = '000000'; M = 'off' }
)
$script:RgbDevices = @()
$script:RgbExe = $null

function ConvertFrom-Hue([double]$H) {
    $x = 1 - [math]::Abs((($H / 60) % 2) - 1)
    switch ([int]([math]::Floor($H / 60) % 6)) {
        0 { $r = 1; $g = $x; $b = 0 }
        1 { $r = $x; $g = 1; $b = 0 }
        2 { $r = 0; $g = 1; $b = $x }
        3 { $r = 0; $g = $x; $b = 1 }
        4 { $r = $x; $g = 0; $b = 1 }
        default { $r = 1; $g = 0; $b = $x }
    }
    return ('{0:X2}{1:X2}{2:X2}' -f [int]($r * 255), [int]($g * 255), [int]($b * 255))
}

function Set-RgbColor([string]$Hex) {
    $Hex = $Hex.Trim().TrimStart('#').ToUpper()
    if ($Hex -notmatch '^[0-9A-F]{6}$') { return }
    $script:Rgb.Hex = $Hex
    $ui.rgbPreview.Fill = New-Brush "#$Hex"
    $col = [System.Windows.Media.ColorConverter]::ConvertFromString("#$Hex")
    $glow = New-Object System.Windows.Media.RadialGradientBrush
    $glow.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(190, $col.R, $col.G, $col.B)), 0))
    $glow.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0, $col.R, $col.G, $col.B)), 1))
    $ui.rgbPreviewGlow.Fill = $glow
    if (-not $script:RgbSyncing -and ($ui.txtRgbHex.Text.TrimStart('#').ToUpper() -ne $Hex)) {
        $script:RgbSyncing = $true
        $ui.txtRgbHex.Text = $Hex
        $script:RgbSyncing = $false
    }
}

function Update-RgbModeButtons {
    foreach ($b in $ui.wpRgbModes.Children) {
        if ($b.Tag -eq $script:Rgb.Mode) { $b.Style = $window.FindResource('Primary') }
        else { $b.Style = $window.FindResource([System.Windows.Controls.Button]) }
    }
}

function Save-RgbPrefs {
    Set-Reg $script:ColorRegPath 'RgbHex' $script:Rgb.Hex 'String'
    Set-Reg $script:ColorRegPath 'RgbMode' $script:Rgb.Mode 'String'
    Set-Reg $script:ColorRegPath 'RgbBright' ([int]$script:Rgb.Bright) 'DWord'
}

function Find-OpenRgb {
    $saved = Get-Reg $script:ColorRegPath 'OpenRgbPath'
    if ($saved -and (Test-Path -LiteralPath $saved)) { return [string]$saved }
    $cands = @("$env:ProgramFiles\OpenRGB\OpenRGB.exe", "${env:ProgramFiles(x86)}\OpenRGB\OpenRGB.exe", "$env:LOCALAPPDATA\Programs\OpenRGB\OpenRGB.exe")
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $pkgRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $pkgRoot) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $pkgRoot -Directory -Filter '*OpenRGB*' -ErrorAction SilentlyContinue)) {
            $exe = Get-ChildItem -LiteralPath $dir.FullName -Recurse -Filter 'OpenRGB.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    $cmd = Get-Command 'OpenRGB.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Update-RgbStatus {
    $script:RgbExe = Find-OpenRgb
    if ($script:RgbExe) {
        $ui.txtRgbStatus.Text = 'OpenRGB pronto'
        $ui.txtRgbStatusSub.Text = "Encontrado em: $($script:RgbExe)`nEscolha a cor e o efeito e clique em Aplicar."
        $ui.btnRgbInstall.Visibility = 'Collapsed'
        $ui.btnRgbOpen.Visibility = 'Visible'
        $ui.btnRgbServer.Visibility = 'Visible'
        $ui.btnRgbApply.IsEnabled = $true
        $ui.btnRgbScan.IsEnabled = $true
    } else {
        $ui.txtRgbStatus.Text = 'Falta instalar o OpenRGB'
        $ui.txtRgbStatusSub.Text = 'O painel usa o OpenRGB, um programa gratuito e de código aberto que controla os LEDs de milhares de peças de várias marcas. Instale com um clique e volte para esta aba.'
        $ui.btnRgbInstall.Visibility = 'Visible'
        $ui.btnRgbOpen.Visibility = 'Collapsed'
        $ui.btnRgbServer.Visibility = 'Collapsed'
        $ui.btnRgbApply.IsEnabled = $false
        $ui.btnRgbScan.IsEnabled = $false
    }
}

function Set-RgbBusy([bool]$Busy) {
    $ui.txtRgbBusy.Text = if ($Busy) { $script:RgbLabel } else { 'pronto' }
    $ui.txtRgbBusy.Foreground = if ($Busy) { New-Brush '#FACC15' } else { New-Brush '#9D93C4' }
    $ui.btnRgbApply.IsEnabled = (-not $Busy) -and [bool]$script:RgbExe
    $ui.btnRgbScan.IsEnabled = (-not $Busy) -and [bool]$script:RgbExe
}

# Roda o OpenRGB escondido, sem travar a janela, e lê a resposta quando terminar
$script:RgbTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RgbTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:RgbTimer.Add_Tick({
    $p = $script:RgbProc
    if (-not $p) { $script:RgbTimer.Stop(); return }
    if (-not $p.HasExited) {
        if (((Get-Date) - $script:RgbStart).TotalSeconds -lt 60) { return }
        try { $p.Kill() } catch {}
        Write-Log 'O OpenRGB demorou demais e foi interrompido.' 'warn'
    }
    $script:RgbTimer.Stop()
    $txt = ''
    foreach ($f in $script:RgbOut, $script:RgbErr) {
        try { $t = Get-Content -LiteralPath $f -Raw -ErrorAction Stop; if ($t) { $txt += "$t`n" } } catch {}
    }
    $script:RgbProc = $null
    Set-RgbBusy $false
    if ($script:RgbDone) { try { & $script:RgbDone $txt } catch { Write-Log $_.Exception.Message 'err' } }
})

function Start-RgbCommand([string[]]$CliArgs, [string]$Label, [scriptblock]$OnDone) {
    if (-not $script:RgbExe) { Write-Log 'Instale o OpenRGB primeiro (aba Iluminação RGB).' 'warn'; return }
    if ($script:RgbProc -and -not $script:RgbProc.HasExited) { Write-Log 'Aguarde o comando de LED anterior terminar.' 'warn'; return }
    $script:RgbOut = Join-Path $env:TEMP 'optimizergbz_openrgb_out.txt'
    $script:RgbErr = Join-Path $env:TEMP 'optimizergbz_openrgb_err.txt'
    Remove-Item -LiteralPath $script:RgbOut, $script:RgbErr -ErrorAction SilentlyContinue
    $argStr = ($CliArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    try {
        $script:RgbProc = Start-Process -FilePath $script:RgbExe -ArgumentList $argStr -NoNewWindow -PassThru `
            -WorkingDirectory (Split-Path -Parent $script:RgbExe) -RedirectStandardOutput $script:RgbOut -RedirectStandardError $script:RgbErr
    } catch {
        Write-Log "Não consegui abrir o OpenRGB: $($_.Exception.Message)" 'err'
        return
    }
    $script:RgbStart = Get-Date
    $script:RgbDone = $OnDone
    $script:RgbLabel = $Label
    Set-RgbBusy $true
    $script:RgbTimer.Start()
}

function Invoke-RgbApply {
    $mode = $script:Rgb.Mode; $hex = $script:Rgb.Hex
    if ($mode -eq 'off') { $mode = 'static'; $hex = '000000' }
    $one = @('-m', $mode)
    if ($mode -ne 'rainbow') { $one += @('-c', $hex) }
    if ($script:Rgb.Mode -ne 'off') { $one += @('-b', [string][int]$script:Rgb.Bright) }
    $cli = @()
    $sel = @($script:RgbDevices | Where-Object { $_.CheckBox -and $_.CheckBox.IsChecked })
    if ($sel.Count -gt 0) { foreach ($d in $sel) { $cli += @('-d', [string]$d.Index) + $one } }
    else { $cli = $one }
    Save-RgbPrefs
    Write-Log "Aplicando LED: $($script:Rgb.Mode) #$($script:Rgb.Hex)..."
    Start-RgbCommand $cli 'aplicando...' {
        param($out)
        $errs = @($out -split "`r?`n" | Where-Object { $_ -match '(?i)error|not supported|invalid' })
        if ($errs.Count -gt 0) { Write-Log "Algumas peças não aceitaram esse efeito: $($errs[0..([math]::Min(1, $errs.Count - 1))] -join ' | '). Tente o Estático." 'warn' }
        else { Write-Log 'Iluminação aplicada!' 'ok' }
    }
}

function Invoke-RgbScan {
    $ui.txtRgbDevHint.Text = 'Procurando dispositivos... pode levar até 30 segundos.'
    Start-RgbCommand @('--list-devices') 'procurando peças...' {
        param($out)
        $ui.spRgbDevices.Children.Clear()
        $list = @(); $cur = $null
        foreach ($line in ($out -split "`r?`n")) {
            if ($line -match '^\s*(\d+):\s*(.+?)\s*$') { $cur = @{ Index = $Matches[1]; Nome = $Matches[2]; Tipo = ''; Modos = '' }; $list += $cur }
            elseif ($cur -and $line -match '^\s+Type:\s*(.+)$') { $cur.Tipo = $Matches[1].Trim() }
            elseif ($cur -and $line -match '^\s+Modes:\s*(.+)$') { $cur.Modos = ($Matches[1] -replace '[\[\]]', '').Trim() }
        }
        $script:RgbDevices = $list
        if ($list.Count -eq 0) {
            $ui.txtRgbDevHint.Text = 'Nenhuma peça encontrada. Feche os programas da marca (Armoury Crate, iCUE...), instale o PawnIO e tente de novo. Se continuar, suas peças podem não ser suportadas pelo OpenRGB.'
            Write-Log 'O OpenRGB não encontrou peças de LED.' 'warn'
            return
        }
        $ui.txtRgbDevHint.Text = "$($list.Count) peças encontradas. Marque as que quer controlar (nenhuma marcada = todas)."
        $i = 0
        foreach ($d in $list) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Style = $window.FindResource('Switch')
            $info = @()
            if ($d.Tipo) { $info += $d.Tipo }
            if ($d.Modos) { $info += "Efeitos: $($d.Modos)" }
            $cb.Content = New-SwitchContent $d.Nome ($info -join '  |  ') $null
            $d.CheckBox = $cb
            Invoke-EnterAnim $cb ($i * 50) 10; $i++
            [void]$ui.spRgbDevices.Children.Add($cb)
        }
        Write-Log "OpenRGB encontrou $($list.Count) peças de LED." 'ok'
    }
}

function Build-RgbPage {
    foreach ($hx in $script:RgbSwatches) {
        $b = New-Object System.Windows.Controls.Button
        $b.Tag = $hx
        $b.Width = 34; $b.Height = 34; $b.Cursor = 'Hand'; $b.Margin = New-Object System.Windows.Thickness 0, 0, 10, 10
        $tpl = [Windows.Markup.XamlReader]::Parse('<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button"><Grid><Ellipse Fill="{TemplateBinding Background}" Stroke="#55FFFFFF" StrokeThickness="2"/></Grid></ControlTemplate>')
        $b.Template = $tpl
        $b.Background = New-Brush "#$hx"
        $b.Add_Click({ param($s, $e) Set-RgbColor $s.Tag; if ($script:Rgb.Mode -eq 'off') { $script:Rgb.Mode = 'static'; Update-RgbModeButtons } })
        [void]$ui.wpRgbSwatches.Children.Add($b)
    }
    foreach ($name in $script:RgbModes.Keys) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $name; $b.Tag = $script:RgbModes[$name]
        $b.Add_Click({ param($s, $e) $script:Rgb.Mode = $s.Tag; Update-RgbModeButtons })
        [void]$ui.wpRgbModes.Children.Add($b)
    }
    foreach ($sc in $script:RgbScenes) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $window.FindResource('ProfileCard')
        $b.Tag = $sc
        $sp = New-Object System.Windows.Controls.StackPanel
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 26; $dot.Height = 26; $dot.HorizontalAlignment = 'Left'
        if ($sc.M -eq 'rainbow') { $dot.Fill = $window.FindResource('HueGrad') }
        elseif ($sc.M -eq 'off') { $dot.Fill = New-Brush '#000000'; $dot.Stroke = New-Brush '#55FFFFFF'; $dot.StrokeThickness = 2 }
        else { $dot.Fill = New-Brush "#$($sc.Hex)" }
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $sc.N; $nm.FontWeight = 'Black'; $nm.FontSize = 14; $nm.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
        [void]$sp.Children.Add($dot); [void]$sp.Children.Add($nm)
        $b.Content = $sp
        $b.Add_Click({
            param($s, $e)
            $sc2 = $s.Tag
            $script:Rgb.Mode = $sc2.M
            if ($sc2.M -ne 'rainbow') { Set-RgbColor $sc2.Hex }
            Update-RgbModeButtons
            Invoke-RgbApply
        })
        [void]$ui.ugRgbScenes.Children.Add($b)
    }

    # Preferências salvas
    $h = Get-Reg $script:ColorRegPath 'RgbHex'; if ($h) { $script:Rgb.Hex = [string]$h }
    $m = Get-Reg $script:ColorRegPath 'RgbMode'; if ($m) { $script:Rgb.Mode = [string]$m }
    $br = Get-Reg $script:ColorRegPath 'RgbBright'; if ($null -ne $br) { $script:Rgb.Bright = [int]$br }
    $ui.sldRgbBright.Value = $script:Rgb.Bright
    $ui.txtRgbBright.Text = "$([int]$script:Rgb.Bright)%"
    Set-RgbColor $script:Rgb.Hex
    Update-RgbModeButtons
    $ui.chkRgbGamer.IsChecked = ((Get-Reg $script:ColorRegPath 'RgbGamer') -eq 1)

    $ui.sldHue.Add_ValueChanged({ if (-not $script:RgbSyncing) { Set-RgbColor (ConvertFrom-Hue $ui.sldHue.Value); if ($script:Rgb.Mode -eq 'off') { $script:Rgb.Mode = 'static'; Update-RgbModeButtons } } })
    $ui.txtRgbHex.Add_TextChanged({ if (-not $script:RgbSyncing) { $script:RgbSyncing = $true; try { Set-RgbColor $ui.txtRgbHex.Text } finally { $script:RgbSyncing = $false } } })
    $ui.sldRgbBright.Add_ValueChanged({ $script:Rgb.Bright = [int]$ui.sldRgbBright.Value; $ui.txtRgbBright.Text = "$([int]$ui.sldRgbBright.Value)%" })
    $ui.chkRgbGamer.Add_Checked({ Set-Reg $script:ColorRegPath 'RgbGamer' 1; Save-RgbPrefs; Write-Log 'O Modo Gamer agora também muda o LED.' 'ok' })
    $ui.chkRgbGamer.Add_Unchecked({ Set-Reg $script:ColorRegPath 'RgbGamer' 0 })
    Update-RgbStatus
}

# ------------------------------------------------------------------
# 11d. Discord (Rich Presence pelo canal local do Discord, sem login)
# ------------------------------------------------------------------
# Status no Discord: desativado por enquanto. Para religar, troque para $true.
$script:DiscordEnabled = $false
$script:DC = [hashtable]::Synchronized(@{
    Run = $true; Enabled = $false; ClientId = ''; Details = 'Otimizando o PC'; State = 'Na aba Painel'
    Start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); LargeImage = 'logo'; Pid = $PID; Dirty = $true; Status = 'off'; LastError = ''
})
$script:DcScript = {
    param($D)
    function Send-Frame($Pipe, [int]$Op, [string]$Json) {
        $b = [Text.Encoding]::UTF8.GetBytes($Json)
        $h = [BitConverter]::GetBytes($Op) + [BitConverter]::GetBytes($b.Length)
        $Pipe.Write([byte[]]$h, 0, 8); $Pipe.Write($b, 0, $b.Length); $Pipe.Flush()
    }
    function Read-Frame($Pipe) {
        $h = New-Object byte[] 8; $n = 0
        while ($n -lt 8) { $r = $Pipe.Read($h, $n, 8 - $n); if ($r -le 0) { throw 'fechado' }; $n += $r }
        $len = [BitConverter]::ToInt32($h, 4)
        $buf = New-Object byte[] $len; $n = 0
        while ($n -lt $len) { $r = $Pipe.Read($buf, $n, $len - $n); if ($r -le 0) { throw 'fechado' }; $n += $r }
        return [Text.Encoding]::UTF8.GetString($buf)
    }
    $pipe = $null; $connectedId = ''
    while ($D.Run) {
        try {
            if (-not $D.Enabled -or -not $D.ClientId) {
                if ($pipe) { $pipe.Dispose(); $pipe = $null; $connectedId = '' }
                $D.Status = 'off'; Start-Sleep -Milliseconds 500; continue
            }
            if (-not $pipe -or -not $pipe.IsConnected -or $connectedId -ne $D.ClientId) {
                if ($pipe) { $pipe.Dispose(); $pipe = $null }
                $D.Status = 'connecting'
                for ($i = 0; ($i -lt 10) -and -not $pipe; $i++) {
                    try {
                        $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', "discord-ipc-$i", [System.IO.Pipes.PipeDirection]::InOut)
                        $c.Connect(300); $pipe = $c
                    } catch {}
                }
                if (-not $pipe) { $D.Status = 'nodiscord'; Start-Sleep -Seconds 5; continue }
                Send-Frame $pipe 0 ('{"v":1,"client_id":"' + $D.ClientId + '"}')
                $resp = Read-Frame $pipe
                if ($resp -notmatch '"READY"') {
                    $D.Status = 'badid'; $D.LastError = $resp; $pipe.Dispose(); $pipe = $null
                    $bad = $D.ClientId
                    while ($D.Run -and $D.Enabled -and $D.ClientId -eq $bad) { Start-Sleep -Milliseconds 500 }
                    continue
                }
                $connectedId = $D.ClientId; $D.Status = 'online'; $D.Dirty = $true
            }
            if ($D.Dirty) {
                $D.Dirty = $false
                $act = @{
                    details = [string]$D.Details; state = [string]$D.State
                    timestamps = @{ start = [int64]$D.Start }
                    assets = @{ large_image = [string]$D.LargeImage; large_text = 'Optimizer GBZ by n0ctlow' }
                }
                $payload = @{ cmd = 'SET_ACTIVITY'; args = @{ pid = [int]$D.Pid; activity = $act }; nonce = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 6 -Compress
                Send-Frame $pipe 1 $payload
                $r = Read-Frame $pipe
                if ($r -match '"evt":"ERROR"') { $D.LastError = $r }
                Start-Sleep -Seconds 4
            }
            Start-Sleep -Milliseconds 400
        } catch {
            try { if ($pipe) { $pipe.Dispose() } } catch {}
            $pipe = $null; $connectedId = ''
            if ($D.Run) { $D.Status = 'nodiscord'; Start-Sleep -Seconds 3 }
        }
    }
    try { if ($pipe) { $pipe.Dispose() } } catch {}
}

function Start-DiscordLink {
    $script:DcPS = [powershell]::Create()
    [void]$script:DcPS.AddScript($script:DcScript).AddArgument($script:DC)
    $script:DcHandle = $script:DcPS.BeginInvoke()
}
function Stop-DiscordLink {
    $script:DC.Run = $false
    try { [void]$script:DcPS.BeginStop($null, $null) } catch {}
}

function Update-DiscordPresence {
    $det = if ($script:GamerOn) { 'Modo Gamer ativado' } else { 'Otimizando o PC' }
    $title = 'Painel'
    if ($script:CurrentNav -and $script:Pages.Contains($script:CurrentNav)) { $title = $script:Pages[$script:CurrentNav].Title }
    $st = "Na aba $title"
    if ($script:DC.Details -ne $det -or $script:DC.State -ne $st) {
        $script:DC.Details = $det; $script:DC.State = $st; $script:DC.Dirty = $true
    }
    try { $ui.txtDcPrevDetails.Text = $det; $ui.txtDcPrevState.Text = $st } catch {}
}

function Update-DiscordStatus {
    $map = @{
        off        = @('desligado', '#4A3F70')
        connecting = @('conectando...', '#FACC15')
        nodiscord  = @('Discord não está aberto', '#FF4D6D')
        badid      = @('ID inválido', '#FF4D6D')
        online     = @('online no seu perfil', '#39FF88')
    }
    $st = [string]$script:DC.Status
    if (-not $map.ContainsKey($st)) { return }
    if ($script:LastDcStatus -ne $st) {
        $script:LastDcStatus = $st
        if ($st -eq 'online') { Write-Log 'Discord conectado: seu perfil agora mostra o Optimizer GBZ.' 'ok' }
        if ($st -eq 'badid') { Write-Log 'O Discord recusou o ID do aplicativo. Confira se copiou o Application ID certo.' 'warn' }
    }
    $ui.txtDcStatus.Text = $map[$st][0]
    $ui.dcDot.Fill = New-Brush $map[$st][1]
    $el = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$script:DC.Start
    $ui.txtDcPrevTime.Text = ('{0:00}:{1:00} decorrido' -f [math]::Floor($el / 60), ($el % 60))
}

# ------------------------------------------------------------------
# 11e. Música (controles de mídia do Windows: Spotify, navegador etc.)
# ------------------------------------------------------------------
$script:Media = @{ Ok = $false; Key = ''; Playing = $false }

function Wait-WinRt($Op, [Type]$T) {
    $task = $script:AsTaskOp.MakeGenericMethod($T).Invoke($null, @($Op))
    if (-not $task.Wait(1500)) { return $null }
    return $task.Result
}

function Initialize-Media {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
        $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType,Windows.Storage.Streams,ContentType=WindowsRuntime]
        $script:AsTaskOp = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
        $script:MediaMgr = Wait-WinRt ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        $script:Media.Ok = [bool]$script:MediaMgr
    } catch {
        $script:Media.Ok = $false
        Write-Log "Player de música indisponível neste Windows: $($_.Exception.Message)" 'warn'
    }
}

# Vinil girando + visualizador dançando enquanto a música toca
function Set-Equalizer([bool]$On) {
    $rt = $ui.vinyl.RenderTransform
    if ($On) {
        $secs = if ($ui.chkParty.IsChecked) { 1.6 } else { 3.6 }
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation ($rt.Angle), ($rt.Angle + 360), (New-Duration ([int]($secs * 1000)))
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
    } else {
        $cur = $rt.Angle
        $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $rt.Angle = $cur % 360
    }
    foreach ($bar in $ui.spViz.Children) {
        $st = $bar.RenderTransform
        if ($On) {
            $hi = 0.35 + $script:Rnd.NextDouble() * 0.65
            $a = New-Loop (0.05 + $script:Rnd.NextDouble() * 0.15) $hi (0.22 + $script:Rnd.NextDouble() * 0.45)
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
        } else {
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
            $st.ScaleY = 0.06
        }
    }
    $ui.txtMusicState.Text = if ($On) { 'TOCANDO' } else { 'PAUSADO' }
    $ui.chipMusicState.Background = if ($On) { New-Brush '#39FF88' } else { New-Brush '#33FFFFFF' }
    $ui.txtMusicState.Foreground = if ($On) { New-Brush '#0B0716' } else { New-Brush '#FFFFFF' }
    if ($script:MusicReady) { Set-MusicMood $On }
}

$script:MoodPlay = @(
    'faixa detectada. volume no talo recomendado.', 'CPU dançando a 120 BPM.', 'essa aqui é braba.', 'o vizinho que lute.',
    'sincronizando vibes... [OK]', 'nível de hype: acima de 9000.', 'o PC aprovou essa.', 'modo foco: ativado.',
    'essa merece repeat.', 'ventoinhas no ritmo.', 'qualidade de áudio: lendária.', 'detectado: música de tryhard.'
)
$script:MoodPause = @('pausa estratégica.', 'silêncio tático.', 'o PC tá esperando o drop.', 'respira e volta.', 'AFK musical detectado.')
$script:Session = @{ Songs = 0; Seconds = 0.0; Artists = @{}; LastTick = $null }
$script:FeedLines = New-Object System.Collections.Generic.List[string]

function Add-MusicFeed([string]$Line) {
    $script:FeedLines.Add("[$(Get-Date -Format HH:mm)] $Line")
    while ($script:FeedLines.Count -gt 8) { $script:FeedLines.RemoveAt(0) }
    $ui.txtMusicFeed.Text = ($script:FeedLines -join "`n")
}

function Set-MusicMood([bool]$Playing) {
    $list = if ($Playing) { $script:MoodPlay } else { $script:MoodPause }
    $m = $list[$script:Rnd.Next(0, $list.Count)]
    $ui.txtMusicMood.Text = "> $m"
    Invoke-EnterAnim $ui.txtMusicMood 0 6
    Add-MusicFeed "> $m"
}

function Build-MusicPage {
    for ($i = 0; $i -lt 44; $i++) {
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = 7; $r.Height = 116; $r.RadiusX = 2; $r.RadiusY = 2
        $r.Margin = New-Object System.Windows.Thickness 2, 0, 2, 0
        $r.VerticalAlignment = 'Bottom'
        $r.Fill = $window.FindResource('GaugeGrad')
        $r.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 1
        $st = New-Object System.Windows.Media.ScaleTransform 1, 0.06
        $r.RenderTransform = $st
        [void]$ui.spViz.Children.Add($r)
    }
    $ui.chkCoverTint.IsChecked = ((Get-Reg $script:ColorRegPath 'MusicTint') -ne 0)
    $ui.chkParty.IsChecked = ((Get-Reg $script:ColorRegPath 'MusicParty') -eq 1)
    $ui.chkMusicRgb.IsChecked = ((Get-Reg $script:ColorRegPath 'MusicRgb') -eq 1)
    $ui.chkCoverTint.Add_Checked({ Set-Reg $script:ColorRegPath 'MusicTint' 1; if ($script:CoverColor) { Set-MusicTint $script:CoverColor } })
    $ui.chkCoverTint.Add_Unchecked({ Set-Reg $script:ColorRegPath 'MusicTint' 0; Set-MusicTint $null })
    $ui.chkParty.Add_Checked({ Set-Reg $script:ColorRegPath 'MusicParty' 1; Set-PartyMode $true; Invoke-Confetti })
    $ui.chkParty.Add_Unchecked({ Set-Reg $script:ColorRegPath 'MusicParty' 0; Set-PartyMode $false })
    $ui.chkMusicRgb.Add_Checked({
        Set-Reg $script:ColorRegPath 'MusicRgb' 1
        if (-not $script:RgbExe) { Write-Log 'Para o LED acompanhar a capa, instale o OpenRGB na aba Iluminação RGB.' 'warn' }
    })
    $ui.chkMusicRgb.Add_Unchecked({ Set-Reg $script:ColorRegPath 'MusicRgb' 0 })
    $script:MusicReady = $true
    if ($ui.chkParty.IsChecked) { Set-PartyMode $true }
}

# Modo festa: borda que troca de cor e visualizador arco-íris
function Set-PartyMode([bool]$On) {
    foreach ($bar in $ui.spViz.Children) { $bar.Fill = if ($On) { $window.FindResource('HueGrad') } else { $window.FindResource('GaugeGrad') } }
    if ($On) {
        $br = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(232, 121, 249))
        $ui.musicHero.BorderBrush = $br
        $ui.musicHero.BorderThickness = New-Object System.Windows.Thickness 2
        $ca = New-Object System.Windows.Media.Animation.ColorAnimationUsingKeyFrames
        $ca.Duration = New-Duration 2400
        $ca.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $t = 0
        foreach ($hx in '#E879F9', '#22D3EE', '#39FF88', '#FACC15', '#E879F9') {
            $kf = New-Object System.Windows.Media.Animation.LinearColorKeyFrame ([System.Windows.Media.ColorConverter]::ConvertFromString($hx)), ([System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($t)))
            [void]$ca.KeyFrames.Add($kf); $t += 600
        }
        $br.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
    } else {
        $ui.musicHero.ClearValue([System.Windows.Controls.Border]::BorderBrushProperty)
        $ui.musicHero.ClearValue([System.Windows.Controls.Border]::BorderThicknessProperty)
    }
    if ($script:Media.Playing) { Set-Equalizer $true }
}

# Explosão de confete saindo da capa
function Invoke-Confetti {
    $cv = $ui.confetti
    $cv.Children.Clear()
    $colors = '#E879F9', '#22D3EE', '#39FF88', '#FACC15', '#FF2E88', '#FFFFFF'
    $cx = 110; $cy = 110
    for ($i = 0; $i -lt 46; $i++) {
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = $script:Rnd.Next(5, 10); $r.Height = $script:Rnd.Next(3, 7)
        $r.Fill = New-Brush $colors[$i % $colors.Count]
        [System.Windows.Controls.Canvas]::SetLeft($r, $cx); [System.Windows.Controls.Canvas]::SetTop($r, $cy)
        $tg = New-Object System.Windows.Media.TransformGroup
        $rot = New-Object System.Windows.Media.RotateTransform 0
        $tt = New-Object System.Windows.Media.TranslateTransform 0, 0
        $tg.Children.Add($rot); $tg.Children.Add($tt)
        $r.RenderTransform = $tg
        [void]$cv.Children.Add($r)
        $ang = $script:Rnd.NextDouble() * [math]::PI * 2
        $dist = 90 + $script:Rnd.NextDouble() * 260
        $dur = New-Duration (900 + $script:Rnd.Next(0, 700))
        $ax = New-Object System.Windows.Media.Animation.DoubleAnimation 0, ([math]::Cos($ang) * $dist), $dur
        $ay = New-Object System.Windows.Media.Animation.DoubleAnimation 0, ([math]::Sin($ang) * $dist * 0.6 + 120), $dur
        $ax.EasingFunction = $script:EaseOut
        $ar = New-Object System.Windows.Media.Animation.DoubleAnimation 0, ($script:Rnd.Next(-720, 720)), $dur
        $ao = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, $dur
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $ax)
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ay)
        $rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $ar)
        $r.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $ao)
    }
}

# Cor média da capa (deixada mais viva) para pintar o player
function Get-CoverColor($Bmp) {
    try {
        $small = New-Object System.Windows.Media.Imaging.TransformedBitmap $Bmp, (New-Object System.Windows.Media.ScaleTransform (24 / $Bmp.PixelWidth), (24 / $Bmp.PixelHeight))
        $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap $small, ([System.Windows.Media.PixelFormats]::Bgra32), $null, 0
        $w = $conv.PixelWidth; $h = $conv.PixelHeight
        $px = New-Object byte[] ($w * $h * 4)
        $conv.CopyPixels($px, $w * 4, 0)
        $r = 0.0; $g = 0.0; $b = 0.0; $n = 0
        for ($i = 0; $i -lt $px.Length; $i += 4) {
            $mx = [math]::Max($px[$i + 2], [math]::Max($px[$i + 1], $px[$i])); $mn = [math]::Min($px[$i + 2], [math]::Min($px[$i + 1], $px[$i]))
            $wgt = 1 + ($mx - $mn) / 32
            $b += $px[$i] * $wgt; $g += $px[$i + 1] * $wgt; $r += $px[$i + 2] * $wgt; $n += $wgt
        }
        $r /= $n; $g /= $n; $b /= $n
        $max = [math]::Max($r, [math]::Max($g, $b)); if ($max -lt 1) { $max = 1 }
        $k = 220 / $max
        return [System.Windows.Media.Color]::FromRgb([byte][math]::Min(255, $r * $k), [byte][math]::Min(255, $g * $k), [byte][math]::Min(255, $b * $k))
    } catch { return $null }
}

function Set-MusicTint($Col) {
    if ($Col -and $ui.chkCoverTint.IsChecked) {
        $grad = New-Object System.Windows.Media.LinearGradientBrush
        $grad.StartPoint = New-Object System.Windows.Point 0, 0; $grad.EndPoint = New-Object System.Windows.Point 1, 1
        $c1 = [System.Windows.Media.Color]::FromArgb(255, [byte]($Col.R * 0.55), [byte]($Col.G * 0.55), [byte]($Col.B * 0.55))
        $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop $c1, 0))
        $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(18, 13, 33)), 1))
        $ui.musicHero.Background = $grad
        $ui.vinylLabel.Fill = New-Object System.Windows.Media.SolidColorBrush $Col
    } else {
        $ui.musicHero.ClearValue([System.Windows.Controls.Border]::BackgroundProperty)
        $ui.vinylLabel.Fill = $window.FindResource('PurpleGrad')
    }
}

function Invoke-TrackChanged([string]$Title, [string]$Artist) {
    $script:Session.Songs++
    $ui.txtStatSongs.Text = "$($script:Session.Songs)"
    if ($Artist) {
        if (-not $script:Session.Artists.ContainsKey($Artist)) { $script:Session.Artists[$Artist] = 0 }
        $script:Session.Artists[$Artist]++
        $top = $script:Session.Artists.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        $ui.txtStatArtist.Text = $top.Key
    }
    $hype = [math]::Min(100, $script:Session.Songs * 8 + [math]::Floor($script:Session.Seconds / 60) * 2)
    $ui.txtStatHype.Text = "$hype%"
    Add-MusicFeed ("> tocando: $Title" + $(if ($Artist) { " - $Artist" } else { '' }))
    if ($ui.chkParty.IsChecked) { Invoke-Confetti }
}

function Format-Time([double]$Sec) {
    if ($Sec -lt 0) { $Sec = 0 }
    return ('{0}:{1:00}' -f [math]::Floor($Sec / 60), [math]::Floor($Sec % 60))
}

function Reset-MediaArt {
    $ui.musicArt.Background = $window.FindResource('HeroGrad')
    $ui.musicArtIcon.Visibility = 'Visible'
    $script:CoverColor = $null
    Set-MusicTint $null
}

function Set-MediaArt($Props) {
    try {
        if (-not $Props.Thumbnail) { Reset-MediaArt; return }
        $ras = Wait-WinRt ($Props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
        if (-not $ras) { Reset-MediaArt; return }
        $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ras)
        $ms = New-Object System.IO.MemoryStream
        $net.CopyTo($ms); $net.Dispose(); $ms.Position = 0
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $ms; $bmp.EndInit(); $bmp.Freeze()
        $brush = New-Object System.Windows.Media.ImageBrush $bmp
        $brush.Stretch = 'UniformToFill'
        $ui.musicArt.Background = $brush
        $ui.musicArtIcon.Visibility = 'Collapsed'
        $script:CoverColor = Get-CoverColor $bmp
        Set-MusicTint $script:CoverColor
        if ($script:CoverColor -and $ui.chkMusicRgb.IsChecked -and $script:RgbExe) {
            $hx = '{0:X2}{1:X2}{2:X2}' -f $script:CoverColor.R, $script:CoverColor.G, $script:CoverColor.B
            $script:Rgb.Mode = 'static'; Set-RgbColor $hx; Update-RgbModeButtons; Invoke-RgbApply
        }
    } catch { Reset-MediaArt }
}

function Show-NoMedia {
    if ($script:Media.Key -eq '') { return }
    $script:Media.Key = ''
    $ui.txtMusicTitle.Text = 'Nada tocando'
    $ui.txtMusicArtist.Text = 'Abra o Spotify e dê play'
    $ui.txtMusicApp.Text = 'nenhum player'
    $ui.npPill.Visibility = 'Collapsed'
    $ui.txtMusicPos.Text = '0:00'; $ui.txtMusicEnd.Text = '0:00'
    $ui.txtMusicState.Text = 'PARADO'; $ui.chipMusicState.Background = New-Brush '#33FFFFFF'; $ui.txtMusicState.Foreground = New-Brush '#FFFFFF'
    Set-BarValue $ui.barMusic 0
    Reset-MediaArt
    if ($script:Media.Playing) { $script:Media.Playing = $false; Set-Equalizer $false }
}

function Update-Media {
    if (-not $script:Media.Ok) { return }
    try {
        $sess = $script:MediaMgr.GetCurrentSession()
        if (-not $sess) { Show-NoMedia; return }
        $props = Wait-WinRt ($sess.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        if (-not $props -or -not "$($props.Title)") { Show-NoMedia; return }
        $title = "$($props.Title)"; $artist = "$($props.Artist)"
        $playing = ("$($sess.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing')
        $app = "$($sess.SourceAppUserModelId)"
        $appName = if ($app -match 'Spotify') { 'Spotify' } elseif ($app -match 'chrome') { 'Chrome' } elseif ($app -match 'msedge|Edge') { 'Edge' } elseif ($app -match 'firefox') { 'Firefox' } elseif ($app -match 'opera') { 'Opera' } else { (($app -split '[\\!]')[-1] -replace '\.exe$', '') }
        $key = "$title|$artist"
        if ($key -ne $script:Media.Key) {
            $script:Media.Key = $key
            $ui.txtMusicTitle.Text = $title
            $ui.txtMusicArtist.Text = if ($artist) { $artist } else { $appName }
            Invoke-EnterAnim $ui.txtMusicTitle 0 8
            Invoke-EnterAnim $ui.musicArt 0 14
            Set-MediaArt $props
            Invoke-TrackChanged $title $artist
        }
        $ui.txtMusicApp.Text = $appName
        $ui.txtNpTop.Text = if ($artist) { "$title  -  $artist" } else { $title }
        $ui.npPill.Visibility = 'Visible'
        $glyph = if ($playing) { [string][char]0xE769 } else { [string][char]0xE768 }
        $ui.btnMusicPlay.Content = $glyph; $ui.btnNpTopPlay.Content = $glyph
        if ($playing -ne $script:Media.Playing) { $script:Media.Playing = $playing; Set-Equalizer $playing }
        $now = Get-Date
        if ($playing -and $script:Session.LastTick) { $script:Session.Seconds += ($now - $script:Session.LastTick).TotalSeconds }
        $script:Session.LastTick = $now
        $mins = [math]::Floor($script:Session.Seconds / 60)
        $ui.txtStatTime.Text = if ($mins -ge 60) { '{0}h {1:00}min' -f [math]::Floor($mins / 60), ($mins % 60) } else { "$mins min" }
        $tl = $sess.GetTimelineProperties()
        $end = $tl.EndTime.TotalSeconds
        if ($end -gt 0) {
            $pos = $tl.Position.TotalSeconds
            if ($playing) { $pos += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds }
            $pos = [math]::Min($end, [math]::Max(0, $pos))
            $ui.txtMusicPos.Text = Format-Time $pos
            $ui.txtMusicEnd.Text = Format-Time $end
            Set-BarValue $ui.barMusic ($pos / $end * 100)
        }
    } catch {}
}

function Invoke-MediaCmd([string]$Cmd) {
    if (-not $script:Media.Ok) { return }
    try {
        $sess = $script:MediaMgr.GetCurrentSession()
        if (-not $sess) { Write-Log 'Nenhum player tocando agora.' 'warn'; return }
        switch ($Cmd) {
            'toggle' { [void](Wait-WinRt ($sess.TryTogglePlayPauseAsync()) ([bool])) }
            'next'   { [void](Wait-WinRt ($sess.TrySkipNextAsync()) ([bool])) }
            'prev'   { [void](Wait-WinRt ($sess.TrySkipPreviousAsync()) ([bool])) }
        }
        Start-Sleep -Milliseconds 250
        Update-Media
    } catch {}
}

# ------------------------------------------------------------------
# 12. Inicialização
# ------------------------------------------------------------------
$script:StartupSources = @(
    @{ Origem = 'Registro (sua conta)';      Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
    @{ Origem = 'Registro (todos)';          Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
    @{ Origem = 'Registro (32 bits)';        Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    @{ Origem = 'Pasta Inicializar (sua)';   Folder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup";   Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    @{ Origem = 'Pasta Inicializar (todos)'; Folder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
)

function Get-StartupItems {
    $list = @()
    foreach ($s in $script:StartupSources) {
        $entries = @()
        if ($s.Run) {
            if (Test-Path -LiteralPath $s.Run) {
                $key = Get-Item -LiteralPath $s.Run
                foreach ($n in $key.GetValueNames()) {
                    if ($n) { $entries += [pscustomobject]@{ Name = $n; Cmd = [string]$key.GetValue($n) } }
                }
            }
        } elseif (Test-Path -LiteralPath $s.Folder) {
            foreach ($f in @(Get-ChildItem -LiteralPath $s.Folder -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
                $entries += [pscustomobject]@{ Name = $f.Name; Cmd = $f.FullName }
            }
        }
        foreach ($e in $entries) {
            $disabled = $false
            $b = Get-Reg $s.Approved $e.Name
            if ($b -is [byte[]] -and $b.Length -gt 0) { $disabled = (($b[0] % 2) -eq 1) }
            $status = 'Ativado'
            if ($disabled) { $status = 'Desativado' }
            $list += [pscustomobject]@{ Nome = $e.Name; Status = $status; Origem = $s.Origem; Comando = $e.Cmd; Approved = $s.Approved }
        }
    }
    return $list
}

function Update-StartupList {
    $ui.gridStart.ItemsSource = @(Get-StartupItems | Sort-Object Status, Nome)
}

function Set-StartupState($Item, [bool]$Enable) {
    if (-not (Test-Path -LiteralPath $Item.Approved)) { New-Item -Path $Item.Approved -Force | Out-Null }
    if ($Enable) { $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
    else { $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())) }
    New-ItemProperty -LiteralPath $Item.Approved -Name $Item.Nome -Value $bytes -PropertyType Binary -Force | Out-Null
}

# ------------------------------------------------------------------
# 13. Outras ações
# ------------------------------------------------------------------
function New-RestorePoint {
    Write-Log 'Criando ponto de restauração (pode levar até 1 minuto)...'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description "Optimizer GBZ - $(Get-Date -Format 'dd/MM/yyyy HH:mm')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Ponto de restauração criado com sucesso.' 'ok'
    } catch {
        Write-Log "Não foi possível criar o ponto de restauração: $($_.Exception.Message)" 'err'
        Write-Log 'Dica: ative a Proteção do Sistema em Painel de Controle > Sistema > Proteção do sistema.' 'warn'
    }
}

function Show-DiskHealth {
    Write-Log 'Saúde dos discos:'
    foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $rel = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $hs = "$($d.HealthStatus)"
        $saude = switch ($hs) { 'Healthy' { 'Saudável' } 'Warning' { 'ATENÇÃO' } 'Unhealthy' { 'COM PROBLEMA' } default { $hs } }
        $extra = ''
        if ($rel -and $rel.Temperature) { $extra += " | Temperatura: $($rel.Temperature) °C" }
        if ($rel -and ($null -ne $rel.Wear)) { $extra += " | Desgaste: $($rel.Wear)%" }
        $kind = 'ok'
        if ($hs -ne 'Healthy') { $kind = 'warn' }
        Write-Log "$($d.FriendlyName) [$($d.MediaType)] $(Format-Size $d.Size) - Saúde: $saude$extra" $kind
    }
}

# ------------------------------------------------------------------
# 14. Navegação
# ------------------------------------------------------------------
$script:Pages = [ordered]@{
    navDash  = @{ Page = 'pgDash';  Title = 'Painel';              Sub = 'Seu PC em tempo real.' }
    navGamer = @{ Page = 'pgGamer'; Title = 'Modo Gamer';          Sub = 'Menos input lag, menos travadinhas, mais FPS.' }
    navNet   = @{ Page = 'pgNet';   Title = 'Internet e lag';      Sub = 'Teste de ping, DNS mais rápido e ajustes de rede para jogar.' }
    navLink  = @{ Page = 'pgLink';  Title = 'Música';              Sub = 'Seu Spotify com cara de HUD: vinil, visualizador e modo festa.' }
    navColor = @{ Page = 'pgColor'; Title = 'Tela e cores';        Sub = 'Modos de cor para jogar, ver filme e descansar a vista.' }
    navRgb   = @{ Page = 'pgRgb';   Title = 'Iluminação RGB';      Sub = 'Controle os LEDs do PC de várias marcas num lugar só.' }
    navMem   = @{ Page = 'pgMem';   Title = 'Memória e processos'; Sub = 'Libere RAM e veja o que está pesando.' }
    navClean = @{ Page = 'pgClean'; Title = 'Limpeza';             Sub = 'Libere espaço apagando arquivos desnecessários.' }
    navPerf  = @{ Page = 'pgPerf';  Title = 'Ajustes do Windows';  Sub = 'Energia e ajustes para deixar o Windows leve.' }
    navStart = @{ Page = 'pgStart'; Title = 'Inicialização';       Sub = 'Escolha o que abre junto com o Windows.' }
    navMaint = @{ Page = 'pgMaint'; Title = 'Manutenção';          Sub = 'Reparos, discos, segurança, atualizações e diagnóstico.' }
}
$script:CurrentNav = ''

function Show-Page([string]$Nav) {
    if ($script:CurrentNav -eq $Nav) { return }
    foreach ($k in $script:Pages.Keys) {
        $ui[$script:Pages[$k].Page].Visibility = 'Collapsed'
        $ui[$k].Background = [System.Windows.Media.Brushes]::Transparent
        $ui[$k].Foreground = New-Brush '#B9B0DA'
    }
    $info = $script:Pages[$Nav]
    $page = $ui[$info.Page]
    $page.Visibility = 'Visible'
    $ui[$Nav].Background = $script:NavActiveBg
    $ui[$Nav].Foreground = New-Brush '#FFFFFF'
    $ui.txtPageTitle.Text = $info.Title.ToUpper()
    Start-Typewriter $info.Sub
    Move-NavIndicator $Nav
    $script:CurrentNav = $Nav
    Update-DiscordPresence
    Invoke-EnterAnim $ui.txtPageTitle 0 10

    # Cards entram um de cada vez (efeito cascata)
    $content = $page
    if ($page -is [System.Windows.Controls.ScrollViewer]) { $content = $page.Content }
    if ($content -is [System.Windows.Documents.AdornerDecorator]) { $content = $content.Child }
    if ($content -is [System.Windows.Controls.Panel]) {
        $page.Opacity = 1
        $page.RenderTransform = $null
        $i = 0
        foreach ($c in @($content.Children)) {
            if ($c -is [System.Windows.Controls.Primitives.UniformGrid]) {
                foreach ($cc in @($c.Children)) { Invoke-EnterAnim $cc ($i * 55) 24; $i++ }
            } else {
                Invoke-EnterAnim $c ($i * 55) 24; $i++
            }
        }
    } else {
        Invoke-EnterAnim $page 0 20
    }

    switch ($Nav) {
        'navMem'   { Update-ProcList }
        'navStart' { Update-StartupList }
        'navPerf'  { Update-PowerPlanText }
        'navNet'   { Update-NetInfo $true }
        'navRgb'   {
            Update-RgbStatus
            if ($script:RgbExe -and -not $script:RgbScanned) { $script:RgbScanned = $true; Invoke-RgbScan }
        }
    }
    $window.Dispatcher.BeginInvoke([Action]{
        Update-Sparks
        try {
            Add-HudToPage $script:CurrentNav
            $i = 0
            foreach ($ad in @($script:PageAdorners[$script:CurrentNav])) { Set-HudAnim $ad 14 0.55 (120 + $i * 60) $true; $i++ }
        } catch {}
    }, [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
}
$script:NavActiveBg = New-Object System.Windows.Media.LinearGradientBrush ([System.Windows.Media.Color]::FromArgb(110, 124, 58, 237)), ([System.Windows.Media.Color]::FromArgb(0, 217, 70, 239)), 0

foreach ($k in $script:Pages.Keys) {
    $ui[$k].Tag = $k
    $ui[$k].Add_Click({ param($s, $e) Show-Page $s.Tag })
}

# ------------------------------------------------------------------
# 15. Botões
# ------------------------------------------------------------------

# Janela
$ui.btnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.btnMax.Add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' } })
$ui.btnClose.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    # Minimizado: pausa a atualização da tela e as animações para não gastar nada
    if ($window.WindowState -eq 'Minimized') {
        $timer.Stop()
        if ($script:AmbientOn) { Set-Ambient $false; $script:AmbientPaused = $true }
        return
    }
    if (-not $timer.IsEnabled) { $timer.Start() }
    if ($script:AmbientPaused) { $script:AmbientPaused = $false; Set-Ambient $true }
    if ($window.WindowState -eq 'Maximized') {
        $ui.rootBorder.Margin = New-Object System.Windows.Thickness 7
        $ui.btnMax.Content = [string][char]0xE923
    } else {
        $ui.rootBorder.Margin = New-Object System.Windows.Thickness 0
        $ui.btnMax.Content = [string][char]0xE922
    }
})

# Painel
$ui.btnGamerOn.Add_Click({ Invoke-Task 'Ativando Modo Gamer' { Enable-GamerMode } })
$ui.btnGamerOff.Add_Click({ Invoke-Task 'Voltando ao normal' { Disable-GamerMode } })
$ui.btnQuick.Add_Click({
    Invoke-Task 'Otimização rápida' {
        Write-Log '=== Otimização rápida iniciada ==='
        $freed = Invoke-Clean @($script:CleanItems | Where-Object { $_.Quick })
        $ram = Invoke-FreeRam
        Clear-Dns
        Write-Log "=== Concluído: $(Format-Size $freed) de disco e $([int]$ram) MB de RAM liberados ===" 'ok'
        Show-Msg ("Otimização concluída!`n`nEspaço liberado: {0}`nRAM liberada: {1:N0} MB" -f (Format-Size $freed), $ram) | Out-Null
    }
})
$ui.btnQuickDiag.Add_Click({ Show-Page 'navGamer'; Invoke-Task 'Escaneando' { Invoke-Diagnosis } })
$ui.btnQuickPing.Add_Click({ Show-Page 'navNet'; Invoke-Task 'Testando conexão' { Invoke-PingTest } })
$ui.btnQuickRestore.Add_Click({ Invoke-Task 'Criando ponto de restauração' { New-RestorePoint } })

# Modo Gamer
$ui.btnDiag.Add_Click({ Invoke-Task 'Escaneando' { Invoke-Diagnosis } })
$ui.btnDisplay.Add_Click({ Start-Process 'ms-settings:display-advanced' })

# Tela de acesso
$ui.btnLogin.Add_Click({ Submit-Login })
$ui.txtLoginNick.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Submit-Login } })
$ui.btnChangeNick.Add_Click({ Show-Login })

# Discord e música
$ui.btnDiscordPortal.Add_Click({ Start-Process 'https://discord.com/developers/applications' })
$ui.btnDiscordSave.Add_Click({
    $id = ($ui.txtDiscordId.Text -replace '\D', '')
    if ($id.Length -lt 15) { Show-Msg 'Esse ID parece errado. O Application ID tem uns 18 a 20 números.' 'OK' 'Warning' | Out-Null; return }
    $ui.txtDiscordId.Text = $id
    Set-Reg $script:ColorRegPath 'DiscordId' $id 'String'
    $script:DC.ClientId = $id; $script:DC.Dirty = $true
    if (-not $ui.chkDiscord.IsChecked) { $ui.chkDiscord.IsChecked = $true }
    Write-Log 'ID do Discord salvo.' 'ok'
})
$ui.chkDiscord.Add_Checked({
    if (-not $script:DC.ClientId) { Write-Log 'Cole o ID do aplicativo do Discord e clique em Salvar.' 'warn' }
    $script:DC.Enabled = $true; Set-Reg $script:ColorRegPath 'DiscordOn' 1
})
$ui.chkDiscord.Add_Unchecked({ $script:DC.Enabled = $false; Set-Reg $script:ColorRegPath 'DiscordOn' 0; Write-Log 'Status do Discord desligado.' })
$ui.btnMusicPlay.Add_Click({ Invoke-MediaCmd 'toggle' })
$ui.btnMusicNext.Add_Click({ Invoke-MediaCmd 'next' })
$ui.btnMusicPrev.Add_Click({ Invoke-MediaCmd 'prev' })
$ui.btnNpTopPlay.Add_Click({ Invoke-MediaCmd 'toggle' })
$ui.btnNpTopNext.Add_Click({ Invoke-MediaCmd 'next' })
$ui.btnConfetti.Add_Click({ Invoke-Confetti; Add-MusicFeed '> confete liberado!' })
$ui.btnOpenSpotify.Add_Click({ try { Start-Process 'spotify:' } catch { Start-Process 'https://open.spotify.com' } })

# Iluminação RGB
$ui.btnRgbApply.Add_Click({ Invoke-RgbApply })
$ui.btnRgbScan.Add_Click({ Invoke-RgbScan })
$ui.btnRgbInstall.Add_Click({
    Start-ConsoleTask 'Instalar OpenRGB' 'winget install -e --id OpenRGB.OpenRGB --accept-source-agreements --accept-package-agreements; Write-Host ""; Write-Host "Pronto! Volte ao painel e abra a aba Iluminação RGB de novo." -ForegroundColor Yellow'
    Write-Log 'Se o winget não funcionar, use o botão "Versão mais nova (site oficial)".'
})
$ui.btnRgbSite.Add_Click({ Start-Process 'https://openrgb.org/releases.html' })
$ui.btnRgbPawn.Add_Click({ Start-Process 'https://pawnio.eu' })
$ui.btnRgbBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Onde está o OpenRGB.exe?'
    $dlg.Filter = 'OpenRGB|OpenRGB.exe|Programas|*.exe'
    if ($dlg.ShowDialog($window)) {
        Set-Reg $script:ColorRegPath 'OpenRgbPath' $dlg.FileName 'String'
        Update-RgbStatus
        Write-Log "OpenRGB configurado: $($dlg.FileName)" 'ok'
        $script:RgbScanned = $true
        Invoke-RgbScan
    }
})
$ui.btnRgbOpen.Add_Click({ if ($script:RgbExe) { Start-Process -FilePath $script:RgbExe -WorkingDirectory (Split-Path -Parent $script:RgbExe) } })
$ui.btnRgbServer.Add_Click({
    if (-not $script:RgbExe) { return }
    Start-Process -FilePath $script:RgbExe -ArgumentList '--server --startminimized' -WorkingDirectory (Split-Path -Parent $script:RgbExe)
    Write-Log 'OpenRGB rodando em segundo plano: os próximos comandos de LED ficam bem mais rápidos.' 'ok'
})

# Tela e cores
$ui.btnColorReset.Add_Click({ $p = $script:ColorProfiles['Padrão']; Set-ColorSmooth $p 'Padrão' $p.Desc; Write-Log 'Cores originais restauradas.' 'ok' })

# Internet
$ui.btnPingTest.Add_Click({ Invoke-Task 'Testando conexão' { Invoke-PingTest } })
$ui.btnDnsTest.Add_Click({ Invoke-Task 'Testando DNS' { Invoke-DnsTest } })
$ui.btnDnsBest.Add_Click({
    if (-not $script:BestDns) { return }
    Invoke-Task 'Trocando DNS' {
        Set-DnsAll $script:BestDns.Ips
        Write-Log "DNS alterado para $($script:BestDns.Nome) ($($script:BestDns.Ips -join ', '))." 'ok'
    }
})
$ui.btnDnsAuto.Add_Click({ Invoke-Task 'Restaurando DNS' { Set-DnsAll $null; Write-Log 'DNS voltou para o automático (do roteador/provedor).' 'ok' } })
$ui.btnNetUsers.Add_Click({ Invoke-Task 'Verificando conexões' { Show-NetUsers } })
$ui.btnDns.Add_Click({ Clear-Dns })
$ui.btnRenewIp.Add_Click({ Start-ConsoleTask 'Renovar IP' 'ipconfig /release; ipconfig /renew; ipconfig /flushdns' })
$ui.btnNetReset.Add_Click({
    if (-not (Confirm-Action "Isso reseta as configurações de rede do Windows (Winsock e TCP/IP).`nVocê vai precisar reiniciar o PC. Senhas de Wi-Fi salvas continuam.`n`nContinuar?")) { return }
    Start-ConsoleTask 'Resetar rede' "netsh winsock reset; netsh int ip reset; ipconfig /flushdns; Write-Host ''; Write-Host 'REINICIE O PC para concluir.' -ForegroundColor Yellow"
})

# Memória
$ui.btnFreeRam.Add_Click({ Invoke-Task 'Liberando RAM' { Invoke-FreeRam | Out-Null; Update-ProcList } })
$ui.btnProcRefresh.Add_Click({ Update-ProcList })
$ui.btnProcKill.Add_Click({
    $sel = $ui.gridProc.SelectedItem
    if (-not $sel) { Show-Msg 'Selecione um programa na lista primeiro.' | Out-Null; return }
    if (($script:ProtectedProcs -contains $sel.Nome.ToLower()) -or ($sel.PID -eq $PID)) {
        Show-Msg "'$($sel.Nome)' é um processo essencial do Windows e não deve ser finalizado." 'OK' 'Warning' | Out-Null
        return
    }
    if (-not (Confirm-Action "Finalizar '$($sel.Nome)'?`n`nQualquer trabalho não salvo nesse programa será perdido.")) { return }
    try {
        Stop-Process -Id $sel.PID -Force -ErrorAction Stop
        Write-Log "Processo finalizado: $($sel.Nome) (PID $($sel.PID))" 'ok'
    } catch { Write-Log "Não foi possível finalizar $($sel.Nome): $($_.Exception.Message)" 'err' }
    Start-Sleep -Milliseconds 400
    Update-ProcList
})

# Limpeza
$ui.btnAnalyze.Add_Click({
    Invoke-Task 'Analisando' {
        Write-Log 'Analisando arquivos desnecessários...'
        [double]$total = 0
        foreach ($it in $script:CleanItems) {
            $it.SizeLabel.Text = 'calculando...'
            Update-UI
            $size = Get-TargetsSize (Resolve-CleanTargets $it)
            $it.SizeLabel.Text = Format-Size $size
            if ($it.CheckBox.IsChecked) { $total += $size }
        }
        $ui.txtCleanTotal.Text = "Dá para liberar até $(Format-Size $total) com os itens marcados."
        Write-Log "Análise concluída: $(Format-Size $total) podem ser liberados." 'ok'
    }
})
$ui.btnClean.Add_Click({
    $sel = @($script:CleanItems | Where-Object { $_.CheckBox.IsChecked })
    if ($sel.Count -eq 0) { Show-Msg 'Marque pelo menos um item para limpar.' | Out-Null; return }
    if ($sel | Where-Object { $_.Nome -eq 'Lixeira' }) {
        if (-not (Confirm-Action "A Lixeira está marcada e será esvaziada. Os arquivos dela não poderão ser recuperados.`n`nContinuar?")) { return }
    }
    Invoke-Task 'Limpando' {
        $total = Invoke-Clean $sel
        $ui.txtCleanTotal.Text = "Limpeza concluída: $(Format-Size $total) liberados."
        Write-Log "=== Limpeza concluída: $(Format-Size $total) liberados ===" 'ok'
        Update-Stats
        Show-Msg "Limpeza concluída!`n`n$(Format-Size $total) liberados.`n`nAlguns arquivos podem ter ficado porque estavam em uso, isso é normal." | Out-Null
    }
})
$ui.btnSelAll.Add_Click({ foreach ($it in $script:CleanItems) { $it.CheckBox.IsChecked = $true } })
$ui.btnSelNone.Add_Click({ foreach ($it in $script:CleanItems) { $it.CheckBox.IsChecked = $false } })
$ui.btnCleanMgr.Add_Click({ Start-Process cleanmgr.exe -ArgumentList "/d $env:SystemDrive"; Write-Log 'Limpeza de Disco do Windows aberta. Dica: clique em "Limpar arquivos do sistema" lá dentro.' })
$ui.btnHiber.Add_Click({
    $hf = Get-Item "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    if (-not $hf) { Show-Msg 'A hibernação já está desativada neste PC.' | Out-Null; return }
    $msg = "O arquivo de hibernação ocupa $(Format-Size $hf.Length).`n`nDesativar libera esse espaço, mas o PC perde a opção Hibernar e a Inicialização Rápida. Em notebook que você costuma hibernar, não recomendo.`n`nDesativar?"
    if (-not (Confirm-Action $msg)) { return }
    powercfg /hibernate off
    Write-Log "Hibernação desativada. $(Format-Size $hf.Length) liberados. (Para reativar: powercfg /hibernate on)" 'ok'
    Update-Stats
})

# Ajustes do Windows
$ui.btnPlanBalanced.Add_Click({ [void](Set-PowerPlan 'balanced') })
$ui.btnPlanHigh.Add_Click({ [void](Set-PowerPlan 'high') })
$ui.btnPlanUltimate.Add_Click({ [void](Set-PowerPlan 'ultimate') })

# Inicialização
$ui.btnStartRefresh.Add_Click({ Update-StartupList })
$ui.btnStartDisable.Add_Click({
    $sel = $ui.gridStart.SelectedItem
    if (-not $sel) { Show-Msg 'Selecione um programa na lista primeiro.' | Out-Null; return }
    try { Set-StartupState $sel $false; Write-Log "Não vai mais abrir com o Windows: $($sel.Nome)" 'ok' } catch { Write-Log $_.Exception.Message 'err' }
    Update-StartupList
})
$ui.btnStartEnable.Add_Click({
    $sel = $ui.gridStart.SelectedItem
    if (-not $sel) { Show-Msg 'Selecione um programa na lista primeiro.' | Out-Null; return }
    try { Set-StartupState $sel $true; Write-Log "Vai abrir com o Windows: $($sel.Nome)" 'ok' } catch { Write-Log $_.Exception.Message 'err' }
    Update-StartupList
})
$ui.btnTaskMgr.Add_Click({ Start-Process taskmgr.exe -ArgumentList '/0 /startup' })

# Manutenção
$ui.btnSfc.Add_Click({ Start-ConsoleTask 'Verificar arquivos do sistema' 'sfc /scannow' })
$ui.btnDism.Add_Click({ Start-ConsoleTask 'Reparar imagem do Windows' 'DISM /Online /Cleanup-Image /RestoreHealth' })
$ui.btnDismClean.Add_Click({ Start-ConsoleTask 'Limpar componentes do Windows' 'DISM /Online /Cleanup-Image /StartComponentCleanup' })
$ui.btnChkdsk.Add_Click({ Start-ConsoleTask 'Verificar erros no disco' 'chkdsk $env:SystemDrive /scan' })
$ui.btnDefrag.Add_Click({ Start-ConsoleTask 'Otimizar discos' 'defrag /C /O /U /V' })
$ui.btnDiskHealth.Add_Click({ Invoke-Task 'Verificando discos' { Show-DiskHealth } })
$ui.btnRestore.Add_Click({ Invoke-Task 'Criando ponto de restauração' { New-RestorePoint } })
$ui.btnRstrui.Add_Click({ Start-Process rstrui.exe })
$ui.btnDefender.Add_Click({ Start-ConsoleTask 'Verificação rápida de vírus' 'Start-MpScan -ScanType QuickScan; Write-Host "Resultado:"; Get-MpThreatDetection | Select-Object -First 10 | Format-List' })
$ui.btnWinUpdate.Add_Click({ Start-Process 'ms-settings:windowsupdate' })
$ui.btnWingetList.Add_Click({ Start-ConsoleTask 'Programas desatualizados' 'winget upgrade --accept-source-agreements' })
$ui.btnWingetAll.Add_Click({
    if (-not (Confirm-Action "Isso vai atualizar todos os programas que o winget reconhece.`nFeche os programas abertos antes.`n`nContinuar?")) { return }
    Start-ConsoleTask 'Atualizar todos os programas' 'winget upgrade --all --accept-source-agreements --accept-package-agreements'
})
$ui.btnReliab.Add_Click({ Start-Process perfmon.exe -ArgumentList '/rel' })
$ui.btnBattery.Add_Click({
    $out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'relatorio-bateria.html'
    powercfg /batteryreport /output "$out" | Out-Null
    if (Test-Path $out) { Start-Process $out; Write-Log 'Relatório da bateria salvo na Área de Trabalho.' 'ok' }
    else { Write-Log 'Não foi possível gerar o relatório (este PC tem bateria?).' 'warn' }
})
$ui.btnMemTest.Add_Click({ Start-Process mdsched.exe })

# ------------------------------------------------------------------
# 16. Abrir a janela
# ------------------------------------------------------------------
# Rede de segurança: um erro inesperado vai para o registro em vez de fechar o programa
$window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    try { Write-Log "Erro inesperado: $($e.Exception.Message)" 'err'; Set-Status 'Pronto' $false; $script:Busy = $false } catch {}
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    Update-Ping
    Update-Stats
    if ($script:ColorDirty) { $script:ColorDirty = $false; try { Save-Color } catch {} }
    if ($script:DiscordEnabled) { try { Update-DiscordStatus } catch {} }
    Update-Media
})

$script:UserNick = ''
function Set-UserNick([string]$Nick) {
    $script:UserNick = $Nick
    $ui.txtUserNick.Text = $Nick
    $ui.txtHeroGreet.Text = "Pronto para jogar, $Nick?"
}

function Show-Login {
    $ui.txtLoginNick.Text = $script:UserNick
    $ui.txtLoginErr.Text = ''
    $ui.loginOverlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $ui.loginOverlay.Opacity = 1
    $ui.loginOverlay.Visibility = 'Visible'
    Invoke-EnterAnim $ui.loginCard 0 40
    $window.Dispatcher.BeginInvoke([Action]{ [void]$ui.txtLoginNick.Focus(); $ui.txtLoginNick.SelectAll() }, [System.Windows.Threading.DispatcherPriority]::Input) | Out-Null
}

function Submit-Login {
    $n = $ui.txtLoginNick.Text.Trim()
    if ($n -notmatch '^[\p{L}\p{N}_\-\.]{2,20}$') {
        $ui.txtLoginErr.Text = 'Use de 2 a 20 caracteres: letras, números, _ - ou ponto.'
        $tt = New-Object System.Windows.Media.TranslateTransform 0, 0
        $ui.loginCard.RenderTransform = $tt
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation 16, 0, (New-Duration 450)
        $e = New-Object System.Windows.Media.Animation.ElasticEase; $e.Oscillations = 4; $e.Springiness = 3; $e.EasingMode = 'EaseOut'
        $a.EasingFunction = $e
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a)
        return
    }
    $first = -not $script:UserNick
    Set-Reg $script:ColorRegPath 'UserNick' $n 'String'
    Set-UserNick $n
    Write-Log "Acesso liberado. Bem-vindo, $n!" 'ok'
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, (New-Duration 380)
    $fade.Add_Completed({
        $ui.loginOverlay.Visibility = 'Collapsed'
        $script:CurrentNav = ''
        Show-Page 'navDash'
    })
    $ui.loginOverlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

function Add-BootLine([string]$Text, [double]$Pct) {
    $ui.txtBoot.Text += "> $Text`n"
    Set-BarValue $ui.barBoot $Pct
    Update-UI
}

$window.Add_ContentRendered({
    $script:UiReady = $true
    $ui.txtVersion.Text = "  v$($script:Version)"
    Add-BootLine "INICIALIZANDO OPTIMIZER GBZ v$($script:Version)..." 10
    foreach ($g in $ui.gCpu, $ui.gRam, $ui.gDisk, $ui.gPing, $ui.gScore) { Initialize-Gauge $g }
    Show-Page 'navDash'
    Write-Log 'Optimizer GBZ iniciada. Dica: crie um ponto de restauração antes de mexer nos ajustes.'
    Start-Monitor
    Update-Ping
    Add-BootLine 'MONITOR DE HARDWARE............ [OK]' 30

    # Animações extras: desligadas por padrão; lembra a escolha do usuário
    $tier = [System.Windows.Media.RenderCapability]::Tier -shr 16
    $pref = Get-Reg 'HKCU:\Software\OptimizerGBZ' 'Ambient'
    if ($tier -lt 2) {
        Write-Log 'Sua placa de vídeo está sem aceleração gráfica no Windows (modo software). Deixei as animações extras desligadas para não pesar. Atualizar o driver de vídeo costuma resolver.' 'warn'
    }
    if ($null -eq $pref) { $pref = 1 }
    $ui.chkAmbient.IsChecked = (($pref -eq 1) -and ($tier -ge 2))
    if ($ui.chkAmbient.IsChecked) { Set-Ambient $true }
    $ui.chkAmbient.Add_Checked({ Set-Ambient $true; Set-Reg 'HKCU:\Software\OptimizerGBZ' 'Ambient' 1 })
    $ui.chkAmbient.Add_Unchecked({ Set-Ambient $false; Set-Reg 'HKCU:\Software\OptimizerGBZ' 'Ambient' 0 })
    Build-CleanList
    Add-BootLine 'MÓDULO DE LIMPEZA.............. [OK]' 42
    Build-TweakList $ui.spTweaks $script:WinTweaks
    Build-TweakList $ui.spInput $script:InputTweaks
    Build-TweakList $ui.spStutter $script:StutterTweaks
    Build-TweakList $ui.spNetTweaks $script:NetTweaks
    Add-BootLine 'AJUSTES GAMER E DE REDE........ [OK]' 58
    try { Build-ColorPage; Restore-SavedColor } catch { Write-Log "Tela e cores: $($_.Exception.Message)" 'err' }
    try { Build-RgbPage } catch { Write-Log "Iluminação RGB: $($_.Exception.Message)" 'err' }
    Add-BootLine 'CORES DA TELA E RGB............ [OK]' 72
    Initialize-Media
    $id = Get-Reg $script:ColorRegPath 'DiscordId'
    $id = ([string]$id) -replace '\D', ''
    if ($id) { $ui.txtDiscordId.Text = $id; $script:DC.ClientId = $id }
    if ($script:DiscordEnabled) {
        $ui.cardDiscord.Visibility = 'Visible'
        Start-DiscordLink
        if ((Get-Reg $script:ColorRegPath 'DiscordOn') -eq 1) { $ui.chkDiscord.IsChecked = $true }
    }
    try { Build-MusicPage } catch { Write-Log "Música: $($_.Exception.Message)" 'err' }
    Add-BootLine 'PLAYER DE MÚSICA............... [OK]' 86
    Update-GamerState ((Get-ActivePlanGuid) -eq $script:PlanGuids.ultimate)
    try { $ui.txtSysInfo.Text = Get-SysInfo } catch { $ui.txtSysInfo.Text = 'Não foi possível ler as informações do sistema.' }
    $timer.Start()
    $script:GlitchTimer.Start()
    $saved = [string](Get-Reg $script:ColorRegPath 'UserNick')
    if ($saved -match '^[\p{L}\p{N}_\-\.]{2,20}$') { Set-UserNick $saved }
    if ($script:UserNick) { Add-BootLine "SISTEMA ONLINE. BEM-VINDO, $($script:UserNick.ToUpper())." 100 }
    else { Add-BootLine 'SISTEMA ONLINE. AGUARDANDO IDENTIFICAÇÃO...' 100 }
    Start-Sleep -Milliseconds 350
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, (New-Duration 450)
    $fade.Add_Completed({
        $ui.bootOverlay.Visibility = 'Collapsed'
        if (-not $script:UserNick) { Show-Login; return }
        # repete a entrada da página para ela aparecer animada depois da abertura
        $script:CurrentNav = ''
        Show-Page 'navDash'
    })
    $ui.bootOverlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    Update-Media
})
$window.Add_Closed({ $timer.Stop(); Stop-Monitor; Stop-DiscordLink; try { [GabColor]::ResetSaturation() } catch {} })

[void]$window.ShowDialog()
# Garante que tudo em segundo plano (monitor, Discord) seja encerrado junto com a janela
[Environment]::Exit(0)
