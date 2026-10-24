unit DevWallpaper;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.SyncObjs,
  Vcl.Graphics, Vcl.Controls, Vcl.ExtCtrls;

type
  TWallpaperKind = (wkOff, wkImage, wkMP4);

  TFrameStore = class
  private
    FLock: TCriticalSection;
    FFront, FBack: TBytes;
    FVersion: Cardinal;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Publish(const Data: TBytes);
    procedure Clear;
    function CopyIfNew(var LastVersion: Cardinal; out Data: TBytes): Boolean;
    function Version: Cardinal;
  end;

  TFFmpegThread = class(TThread)
  private
    FPath, FExe: string;
    FRate: Integer;
    FStore: TFrameStore;
    FProcess: THandle;
    FReadPipe: THandle;
    procedure Spawn;
  protected
    procedure Execute; override;
  public
    constructor Create(const AExe, APath: string; ARate: Integer; AStore: TFrameStore);
    procedure StopAndWait;
  end;

  TWallpaperManager = class
  private
    FKind: TWallpaperKind;
    FPath: string;
    FOpacity: Byte;
    FDim: Byte;
    FBlur: Integer;
    FFPS: Integer;
    FDark: Boolean;
    FWholeApp: Boolean;
    FMainHost: TWinControl;
    FBitmap: TBitmap;
    FVideoBitmap: TBitmap;
    FCache: TBitmap;
    FScaled: TBitmap;
    FSoft: TBitmap;
    FDimTile: TBitmap;
    FEditors: TList;
    FSurfaceHooks: TList;
    FTimer: TTimer;
    FStore: TFrameStore;
    FWorker: TFFmpegThread;
    FSeenVersion: Cardinal;
    FCacheVersion: Cardinal;
    FDirty: Boolean;
    FIniPath: string;
    procedure StopVideo;
    procedure TimerTick(Sender: TObject);
    procedure InvalidateEditors;
    procedure RefreshVideoSurfaces;
    procedure SaveSettings;
    procedure RebuildCache(AWidth, AHeight: Integer);
    function CopyLatestFrame: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure LoadSettings;
    function Apply(AKind: TWallpaperKind; const APath: string; AOpacity: Integer;
      ADark: Boolean; ADim, ABlur, AFPS: Integer; AWholeApp: Boolean): Boolean;
    procedure SetMainHost(AHost: TWinControl);
    procedure AddSurface(AControl: TWinControl);
    procedure RemoveSurfaces;
    procedure DrawSurface(ACanvas: TCanvas; const AClip: TRect; AControl: TControl);
    procedure RegisterEditor(AEditor: TControl);
    procedure UnregisterEditor(AEditor: TControl);
    procedure DrawNativeBackground(ACanvas: TCanvas; const AClip: TRect;
      AWidth, AHeight: Integer);
    function Active: Boolean;
    property Kind: TWallpaperKind read FKind;
    property Path: string read FPath;
    property Opacity: Byte read FOpacity;
    property Dim: Byte read FDim;
    property Blur: Integer read FBlur;
    property FPS: Integer read FFPS;
    property DarkUI: Boolean read FDark;
    property WholeApp: Boolean read FWholeApp;
  end;

function EditorWallpaper: TWallpaperManager;
function ShowEditorWallpaperSettings(AOwner: TComponent): Boolean;

implementation

uses
  System.Math, System.IOUtils, System.IniFiles,
  Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.Imaging.jpeg, Vcl.Imaging.pngimage;

const
  VideoWidth = 960;
  VideoHeight = 540;
  FrameBytes = VideoWidth * VideoHeight * 3;

type
  TWallpaperSurfaceHook = class
  private
    FControl: TWinControl;
    FOriginal: TWndMethod;
    FManager: TWallpaperManager;
    FLastNativePaint: Cardinal;
    procedure WndProc(var Msg: TMessage);
    procedure PaintSurface;
    procedure PaintToDC(ADC: HDC);
  public
    constructor Create(AControl: TWinControl; AManager: TWallpaperManager);
    destructor Destroy; override;
  end;

  TWallpaperDialog = class(TForm)
  private
    FMode, FVideoFPS: TComboBox;
    FPath: TEdit;
    FOpacity, FDim, FBlur: TTrackBar;
    FDark: TCheckBox;
    FWholeApp: TCheckBox;
    FBrowse: TButton;
    procedure ModeChange(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    function Confirm(out AKind: TWallpaperKind; out APath: string;
      out AOpacity, ADim, ABlur, AFPS: Integer;
      out ADark, AWholeApp: Boolean): Boolean;
  end;

var
  SharedWallpaper: TWallpaperManager = nil;

function EditorWallpaper: TWallpaperManager;
begin
  if SharedWallpaper = nil then
    SharedWallpaper := TWallpaperManager.Create;
  Result := SharedWallpaper;
end;

function FindFFmpeg: string;
var
  Parts: TStringList;
  I: Integer;
  Candidate: string;
begin
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ';';
    Parts.DelimitedText := GetEnvironmentVariable('PATH');
    for I := 0 to Parts.Count - 1 do
    begin
      Candidate := IncludeTrailingPathDelimiter(
        StringReplace(Trim(Parts[I]), '"', '', [rfReplaceAll])) + 'ffmpeg.exe';
      if FileExists(Candidate) then
      begin
        Result := Candidate;
        Exit;
      end;
    end;
  finally
    Parts.Free;
  end;
end;

procedure PaintAlpha(ADest: TBitmap; const ASource: TBitmap; Alpha: Byte);
var
  Blend: TBlendFunction;
begin
  if (Alpha = 0) or (ASource = nil) or ASource.Empty then Exit;
  Blend.BlendOp := AC_SRC_OVER;
  Blend.BlendFlags := 0;
  Blend.SourceConstantAlpha := Alpha;
  Blend.AlphaFormat := 0;
  Winapi.Windows.AlphaBlend(ADest.Canvas.Handle, 0, 0, ADest.Width, ADest.Height,
    ASource.Canvas.Handle, 0, 0, ASource.Width, ASource.Height, Blend);
end;

constructor TFrameStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TFrameStore.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TFrameStore.Publish(const Data: TBytes);
var
  Temp: TBytes;
begin
  FLock.Enter;
  try
    if Length(FBack) <> Length(Data) then
      SetLength(FBack, Length(Data));
    if Length(Data) > 0 then
      Move(Data[0], FBack[0], Length(Data));
    Temp := FFront;
    FFront := FBack;
    FBack := Temp;
    Inc(FVersion);
  finally
    FLock.Leave;
  end;
end;

procedure TFrameStore.Clear;
begin
  FLock.Enter;
  try
    SetLength(FFront, 0);
    SetLength(FBack, 0);
    Inc(FVersion);
  finally
    FLock.Leave;
  end;
end;

function TFrameStore.Version: Cardinal;
begin
  FLock.Enter;
  try
    Result := FVersion;
  finally
    FLock.Leave;
  end;
end;

function TFrameStore.CopyIfNew(var LastVersion: Cardinal; out Data: TBytes): Boolean;
begin
  FLock.Enter;
  try
    Result := (LastVersion <> FVersion);
    if Result then
    begin
      Data := Copy(FFront, 0, Length(FFront));
      LastVersion := FVersion;
    end;
  finally
    FLock.Leave;
  end;
end;

constructor TFFmpegThread.Create(const AExe, APath: string; ARate: Integer;
  AStore: TFrameStore);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FExe := AExe;
  FPath := APath;
  FRate := ARate;
  FStore := AStore;
  FProcess := 0;
  FReadPipe := 0;
end;

procedure TFFmpegThread.Spawn;
var
  Security: TSecurityAttributes;
  WritePipe: THandle;
  StartInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  Cmd: string;
begin
  FillChar(Security, SizeOf(Security), 0);
  Security.nLength := SizeOf(Security);
  Security.bInheritHandle := True;
  if not CreatePipe(FReadPipe, WritePipe, @Security, 0) then
    RaiseLastOSError;
  try
    if not SetHandleInformation(FReadPipe, HANDLE_FLAG_INHERIT, 0) then
      RaiseLastOSError;
    FillChar(StartInfo, SizeOf(StartInfo), 0);
    FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);
    StartInfo.cb := SizeOf(StartInfo);
    StartInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    StartInfo.wShowWindow := SW_HIDE;
    StartInfo.hStdOutput := WritePipe;
    StartInfo.hStdError := GetStdHandle(STD_ERROR_HANDLE);
    StartInfo.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    Cmd := '"' + FExe + '" -hide_banner -nostdin -loglevel quiet -re ' +
      '-stream_loop -1 -i "' + FPath + '" -an -sn -dn -vf "fps=' +
      IntToStr(FRate) + ',scale=' + IntToStr(VideoWidth) + ':' +
      IntToStr(VideoHeight) + '" -pix_fmt bgr24 -f rawvideo pipe:1';
    UniqueString(Cmd);
    if not CreateProcess(PChar(FExe), PChar(Cmd), nil, nil, True,
      CREATE_NO_WINDOW, nil, nil, StartInfo, ProcessInfo) then
      RaiseLastOSError;
    FProcess := ProcessInfo.hProcess;
    CloseHandle(ProcessInfo.hThread);
  finally
    CloseHandle(WritePipe);
  end;
end;

procedure TFFmpegThread.Execute;
var
  Buffer: TBytes;
  Total, Got: DWORD;
begin
  try
    try
      Spawn;
      SetLength(Buffer, FrameBytes);
      while not Terminated do
      begin
        Total := 0;
      while (Total < FrameBytes) and not Terminated do
      begin
        Got := 0;
        if not ReadFile(FReadPipe, Buffer[Total], FrameBytes - Total, Got, nil) then
          Exit;
        if Got = 0 then Exit;
        Inc(Total, Got);
      end;
      if not Terminated and (Total = FrameBytes) then
        FStore.Publish(Buffer);
      end;
    except
      // Decode failures keep the editor usable and the previous good frame intact.
    end;
  finally
    if FReadPipe <> 0 then
  begin
    CloseHandle(FReadPipe);
    FReadPipe := 0;
  end;
  if FProcess <> 0 then
  begin
    if WaitForSingleObject(FProcess, 0) = WAIT_TIMEOUT then
      TerminateProcess(FProcess, 0);
    CloseHandle(FProcess);
    FProcess := 0;
  end;
  end;
end;

procedure TFFmpegThread.StopAndWait;
begin
  Terminate;
  if FProcess <> 0 then
    TerminateProcess(FProcess, 0); // unblocks a pending pipe ReadFile
  WaitFor;
end;

constructor TWallpaperManager.Create;
begin
  inherited Create;
  FEditors := TList.Create;
  FSurfaceHooks := TList.Create;
  FBitmap := TBitmap.Create;
  FVideoBitmap := TBitmap.Create;
  FCache := TBitmap.Create;
  FScaled := TBitmap.Create;
  FSoft := TBitmap.Create;
  FDimTile := TBitmap.Create;
  FDimTile.PixelFormat := pf24bit;
  FDimTile.SetSize(1, 1);
  FDimTile.Canvas.Brush.Color := clBlack;
  FDimTile.Canvas.FillRect(Rect(0, 0, 1, 1));
  FScaled.PixelFormat := pf24bit;
  FSoft.PixelFormat := pf24bit;
  FBitmap.PixelFormat := pf24bit;
  FVideoBitmap.PixelFormat := pf24bit;
  FCache.PixelFormat := pf24bit;
  FStore := TFrameStore.Create;
  FDirty := True;
  FKind := wkOff;
  FOpacity := 110;
  FDim := 38;
  FBlur := 0;
  FFPS := 24;
  FDark := True;
  FWholeApp := False;
  FMainHost := nil;
  FIniPath := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'),
    'DevCppWallpaper\wallpaper.ini');
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.Interval := 33;
  FTimer.OnTimer := TimerTick;
end;

destructor TWallpaperManager.Destroy;
begin
  FTimer.Enabled := False;
  StopVideo;
  RemoveSurfaces;
  FSurfaceHooks.Free;
  FTimer.Free;
  FMainHost := nil;
  FStore.Free;
  FDimTile.Free;
  FSoft.Free;
  FScaled.Free;
  FCache.Free;
  FVideoBitmap.Free;
  FBitmap.Free;
  FEditors.Free;
  inherited Destroy;
end;

procedure TWallpaperManager.StopVideo;
begin
  FTimer.Enabled := False;
  if FWorker <> nil then
  begin
    FWorker.StopAndWait;
    FreeAndNil(FWorker);
  end;
end;

function TWallpaperManager.Active: Boolean;
begin
  Result := (FKind <> wkOff) and (FOpacity > 0);
end;

procedure TWallpaperManager.LoadSettings;
var
  Ini: TIniFile;
  Mode, Opacity, DimAmount, BlurAmount, Rate: Integer;
  DesiredPath: string;
  Dark: Boolean;
begin
  Ini := TIniFile.Create(FIniPath);
  try
    Mode := EnsureRange(Ini.ReadInteger('Wallpaper', 'Mode', 1), 0, 2);
    DesiredPath := Ini.ReadString('Wallpaper', 'Path',
      ExtractFilePath(ParamStr(0)) + 'editor-background.jpg');
    Opacity := Ini.ReadInteger('Wallpaper', 'Opacity', 110);
    Dark := Ini.ReadBool('Wallpaper', 'DarkUI', True);
    DimAmount := Ini.ReadInteger('Wallpaper', 'Dim', 38);
    BlurAmount := Ini.ReadInteger('Wallpaper', 'Blur', 0);
    Rate := Ini.ReadInteger('Wallpaper', 'FPS', 24);
    FWholeApp := Ini.ReadBool('Wallpaper', 'WholeApp', False);
  finally
    Ini.Free;
  end;
  try
    Apply(TWallpaperKind(Mode), DesiredPath, Opacity, Dark, DimAmount, BlurAmount, Rate,
      FWholeApp);
  except
    FKind := wkOff;
    FDark := Dark;
  end;
end;

procedure TWallpaperManager.SaveSettings;
var
  Ini: TIniFile;
begin
  ForceDirectories(ExtractFileDir(FIniPath));
  Ini := TIniFile.Create(FIniPath);
  try
    Ini.WriteInteger('Wallpaper', 'Mode', Ord(FKind));
    Ini.WriteString('Wallpaper', 'Path', FPath);
    Ini.WriteInteger('Wallpaper', 'Opacity', FOpacity);
    Ini.WriteBool('Wallpaper', 'DarkUI', FDark);
    Ini.WriteInteger('Wallpaper', 'Dim', FDim);
    Ini.WriteInteger('Wallpaper', 'Blur', FBlur);
    Ini.WriteInteger('Wallpaper', 'FPS', FFPS);
    Ini.WriteBool('Wallpaper', 'WholeApp', FWholeApp);
  finally
    Ini.Free;
  end;
end;

function TWallpaperManager.Apply(AKind: TWallpaperKind; const APath: string;
  AOpacity: Integer; ADark: Boolean; ADim, ABlur, AFPS: Integer;
  AWholeApp: Boolean): Boolean;
var
  Picture: TPicture;
  TempImage: TBitmap;
  Executable: string;
begin
  Result := False;
  TempImage := nil;
  Executable := '';
  if AKind <> wkOff then
  begin
    if not FileExists(APath) then
      raise Exception.Create('Wallpaper file not found: ' + APath);
    if AKind = wkMP4 then
    begin
      if not SameText(ExtractFileExt(APath), '.mp4') then
        raise Exception.Create('Video must be an MP4 file');
      if Pos('"', APath) <> 0 then
        raise Exception.Create('Invalid quote in video file path');
      Executable := FindFFmpeg;
      if Executable = '' then
        raise Exception.Create('FFmpeg was not found on PATH');
    end
    else
    begin
      Picture := TPicture.Create;
      TempImage := TBitmap.Create;
      try
        Picture.LoadFromFile(APath);
        TempImage.Assign(Picture.Graphic);
        if TempImage.Empty then
          raise Exception.Create('Wallpaper image is empty');
      finally
        Picture.Free;
      end;
    end;
  end;

  try
    StopVideo;
    FKind := AKind;
    FPath := APath;
    FOpacity := Byte(EnsureRange(AOpacity, 0, 255));
    FDim := Byte(EnsureRange(ADim, 0, 220));
    FBlur := EnsureRange(ABlur, 0, 3);
    FFPS := AFPS;
    if not (FFPS in [12, 24, 30]) then FFPS := 24;
    FDark := ADark;
    FWholeApp := AWholeApp;
    if TempImage <> nil then
      FBitmap.Assign(TempImage)
    else
      FBitmap.SetSize(0, 0);
    FVideoBitmap.SetSize(0, 0);
    FStore.Clear;
    FSeenVersion := FStore.Version;
    FCacheVersion := 0;
    FDirty := True;
    if AKind = wkMP4 then
    begin
      FWorker := TFFmpegThread.Create(Executable, FPath, FFPS, FStore);
      FWorker.Start;
      FTimer.Enabled := True;
    end;
    SaveSettings;
    InvalidateEditors;
    Result := True;
  finally
    TempImage.Free;
  end;
end;

procedure TWallpaperManager.TimerTick(Sender: TObject);
var
  V: Cardinal;
begin
  if FKind <> wkMP4 then Exit;
  V := FStore.Version;
  if V <> FSeenVersion then
  begin
    FSeenVersion := V;
    FDirty := True;
    if FWholeApp then
      RefreshVideoSurfaces
    else
      InvalidateEditors;
  end;
end;

function TWallpaperManager.CopyLatestFrame: Boolean;
var
  Raw: TBytes;
  Y: Integer;
begin
  Result := FStore.CopyIfNew(FCacheVersion, Raw);
  if not Result then Exit;
  if Length(Raw) <> FrameBytes then
  begin
    FVideoBitmap.SetSize(0, 0);
    Exit;
  end;
  FVideoBitmap.PixelFormat := pf24bit;
  FVideoBitmap.SetSize(VideoWidth, VideoHeight);
  for Y := 0 to VideoHeight - 1 do
    Move(Raw[Y * VideoWidth * 3], FVideoBitmap.ScanLine[Y]^,
      VideoWidth * 3);
end;

procedure TWallpaperManager.RebuildCache(AWidth, AHeight: Integer);
var
  Source, Scaled: TBitmap;
  Scale: Double;
  W, H, X, Y: Integer;
  Shrink: Integer;
begin
  if (AWidth <= 0) or (AHeight <= 0) then Exit;
  if FKind = wkMP4 then
    CopyLatestFrame;
  if not FDirty and (FCache.Width = AWidth) and (FCache.Height = AHeight) then Exit;

  FCache.PixelFormat := pf24bit;
  FCache.SetSize(AWidth, AHeight);
  FCache.Canvas.Brush.Color := $00141414;
  FCache.Canvas.FillRect(Rect(0, 0, AWidth, AHeight));
  Source := FBitmap;
  if FKind = wkMP4 then
    Source := FVideoBitmap;
  if not Source.Empty and (FOpacity > 0) then
  begin
    Scaled := FScaled;
    Scaled.PixelFormat := pf24bit;
      Scaled.SetSize(AWidth, AHeight);
      Scaled.Canvas.Brush.Color := $00141414;
      Scaled.Canvas.FillRect(Rect(0, 0, AWidth, AHeight));
      Scale := Max(AWidth / Source.Width, AHeight / Source.Height);
      W := Max(1, Round(Source.Width * Scale));
      H := Max(1, Round(Source.Height * Scale));
      X := (AWidth - W) div 2;
      Y := (AHeight - H) div 2;
      SetStretchBltMode(Scaled.Canvas.Handle, HALFTONE);
      Scaled.Canvas.StretchDraw(Rect(X, Y, X + W, Y + H), Source);
      if FBlur > 0 then
      begin
        // Downscale and upsample only the cached wallpaper, never text.
        Shrink := 2 + FBlur * 3;
        FSoft.SetSize(Max(1, AWidth div Shrink), Max(1, AHeight div Shrink));
        SetStretchBltMode(FSoft.Canvas.Handle, HALFTONE);
        FSoft.Canvas.StretchDraw(Rect(0, 0, FSoft.Width, FSoft.Height), Scaled);
        SetStretchBltMode(Scaled.Canvas.Handle, HALFTONE);
        Scaled.Canvas.StretchDraw(Rect(0, 0, AWidth, AHeight), FSoft);
      end;
      PaintAlpha(FCache, Scaled, FOpacity);
  end;
  if FDim > 0 then
    PaintAlpha(FCache, FDimTile, FDim);
  FDirty := False;
end;

procedure TWallpaperManager.DrawNativeBackground(ACanvas: TCanvas; const AClip: TRect;
  AWidth, AHeight: Integer);
begin
  if not Active then Exit;
  RebuildCache(AWidth, AHeight);
  if FCache.Empty then Exit;
  BitBlt(ACanvas.Handle, AClip.Left, AClip.Top,
    AClip.Right - AClip.Left, AClip.Bottom - AClip.Top,
    FCache.Canvas.Handle, AClip.Left, AClip.Top, SRCCOPY);
end;

constructor TWallpaperSurfaceHook.Create(AControl: TWinControl;
  AManager: TWallpaperManager);
begin
  inherited Create;
  FControl := AControl;
  FManager := AManager;
  FLastNativePaint := 0;
  FOriginal := AControl.WindowProc;
  AControl.WindowProc := WndProc;
  AManager.RegisterEditor(AControl);
end;

destructor TWallpaperSurfaceHook.Destroy;
begin
  if Assigned(FControl) then
  begin
    FControl.WindowProc := FOriginal;
    FManager.UnregisterEditor(FControl);
  end;
  inherited Destroy;
end;

procedure TWallpaperSurfaceHook.WndProc(var Msg: TMessage);
begin
  // Fill the uncovered native surface before VCL/Windows exposes a dark erase.
  // Do not suppress background erasure for populated memos and other controls.
  if (Msg.Msg = WM_ERASEBKGND) and FManager.WholeApp and FManager.Active and
     ((FControl is TTreeView) or (FControl is TListView) or
      (FControl is TPageControl)) then
  begin
    PaintToDC(TWMEraseBkgnd(Msg).DC);
    Msg.Result := 1;
    Exit;
  end;
  FOriginal(Msg);
  if Msg.Msg = WM_PAINT then
  begin
    FLastNativePaint := GetTickCount;
    PaintSurface;
  end;
end;

procedure TWallpaperSurfaceHook.PaintSurface;
var
  DC: HDC;
begin
  if not Assigned(FControl) or not FControl.HandleAllocated then Exit;
  DC := GetDC(FControl.Handle);
  if DC = 0 then Exit;
  try
    PaintToDC(DC);
  finally
    ReleaseDC(FControl.Handle, DC);
  end;
end;

procedure TWallpaperSurfaceHook.PaintToDC(ADC: HDC);
var
  R, ItemRect: TRect;
  Node, NextNode: TTreeNode;
  B: TCanvas;
  Page: TPageControl;
begin
  if (ADC = 0) or (not FManager.WholeApp) or (not FManager.Active) or
     (not Assigned(FControl)) or (not FControl.HandleAllocated) or
     (not FControl.Visible) then Exit;
  R := FControl.ClientRect;
  if FControl is TTreeView then
  begin
    Node := TTreeView(FControl).Items.GetFirstNode;
    while Assigned(Node) do
    begin
      NextNode := Node.GetNextVisible;
      if NextNode = nil then Break;
      Node := NextNode;
    end;
    if Assigned(Node) then
      R.Top := Max(R.Top, Node.DisplayRect(False).Bottom);
  end
  else if FControl is TListView then
  begin
    if TListView(FControl).Items.Count > 0 then
    begin
      ItemRect := TListView(FControl).Items[
        TListView(FControl).Items.Count - 1].DisplayRect(drBounds);
      R.Top := Max(R.Top, ItemRect.Bottom);
    end;
  end
  else if FControl is TMemo then
  begin
    if TMemo(FControl).Lines.Count > 0 then Exit;
  end
  else if FControl is TPageControl then
  begin
    Page := TPageControl(FControl);
    if Page.PageCount > 0 then
    begin
      ItemRect := Page.TabRect(Page.PageCount - 1);
      R.Left := Max(R.Left, ItemRect.Right);
      R.Bottom := Min(R.Bottom, ItemRect.Bottom);
    end
    else
      R.Bottom := Min(R.Bottom, 28);
  end;
  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  B := TCanvas.Create;
  try
    B.Handle := ADC;
    try
      FManager.DrawSurface(B, R, FControl);
    finally
      B.Handle := 0;
    end;
  finally
    B.Free;
  end;
end;

procedure TWallpaperManager.AddSurface(AControl: TWinControl);
var
  I: Integer;
begin
  if not Assigned(AControl) then Exit;
  for I := 0 to FSurfaceHooks.Count - 1 do
    if TWallpaperSurfaceHook(FSurfaceHooks[I]).FControl = AControl then Exit;
  FSurfaceHooks.Add(TWallpaperSurfaceHook.Create(AControl, Self));
end;

procedure TWallpaperManager.RemoveSurfaces;
begin
  while FSurfaceHooks.Count > 0 do
  begin
    TObject(FSurfaceHooks[FSurfaceHooks.Count - 1]).Free;
    FSurfaceHooks.Delete(FSurfaceHooks.Count - 1);
  end;
end;

procedure TWallpaperManager.SetMainHost(AHost: TWinControl);
begin
  FMainHost := AHost;
end;

procedure TWallpaperManager.DrawSurface(ACanvas: TCanvas; const AClip: TRect;
  AControl: TControl);
var
  P: TPoint;
  Width, Height: Integer;
begin
  if not Active then Exit;
  if FWholeApp and Assigned(FMainHost) and Assigned(AControl) then
  begin
    Width := FMainHost.ClientWidth;
    Height := FMainHost.ClientHeight;
    if (Width <= 0) or (Height <= 0) then Exit;
    RebuildCache(Width, Height);
    P := FMainHost.ScreenToClient(AControl.ClientToScreen(Point(0, 0)));
    BitBlt(ACanvas.Handle, AClip.Left, AClip.Top,
      AClip.Right - AClip.Left, AClip.Bottom - AClip.Top,
      FCache.Canvas.Handle, P.X + AClip.Left, P.Y + AClip.Top, SRCCOPY);
  end
  else if Assigned(AControl) then
    DrawNativeBackground(ACanvas, AClip, AControl.Width, AControl.Height);
end;

procedure TWallpaperManager.RegisterEditor(AEditor: TControl);
begin
  if FEditors.IndexOf(AEditor) < 0 then FEditors.Add(AEditor);
end;

procedure TWallpaperManager.UnregisterEditor(AEditor: TControl);
begin
  FEditors.Remove(AEditor);
end;

procedure TWallpaperManager.InvalidateEditors;
var
  I: Integer;
begin
  for I := 0 to FEditors.Count - 1 do
    TControl(FEditors[I]).Invalidate;
end;

procedure TWallpaperManager.RefreshVideoSurfaces;
var
  I, J: Integer;
  Control: TControl;
  Hook: TWallpaperSurfaceHook;
  Hooked: Boolean;
begin
  // Keep the existing native editor path; do not invalidate all VCL panels.
  for I := 0 to FEditors.Count - 1 do
  begin
    Control := TControl(FEditors[I]);
    if Control = FMainHost then Continue;
    Hooked := False;
    for J := 0 to FSurfaceHooks.Count - 1 do
      if TWallpaperSurfaceHook(FSurfaceHooks[J]).FControl = Control then
      begin
        Hooked := True;
        Break;
      end;
    if not Hooked then Control.Invalidate;
  end;

  for I := 0 to FSurfaceHooks.Count - 1 do
  begin
    Hook := TWallpaperSurfaceHook(FSurfaceHooks[I]);
    if (not Hook.FControl.HandleAllocated) or
       (not IsWindowVisible(Hook.FControl.Handle)) then Continue;
    // Native paint/layout takes priority during project and tab loading.
    if GetUpdateRect(Hook.FControl.Handle, nil, False) then Continue;
    if (GetTickCount - Hook.FLastNativePaint) < 90 then Continue;
    Hook.PaintSurface;
  end;
end;

constructor TWallpaperDialog.CreateNew(AOwner: TComponent; Dummy: Integer);
var
  L: TLabel;
  B: TButton;
begin
  inherited CreateNew(AOwner, Dummy);
  Caption := 'Wallpaper Settings - Native Background';
  Width := 555;
  Height := 560;
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  Font.Name := 'Segoe UI';
  Font.Size := 10;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(18, 13, 480, 22);
  L.Caption := 'Mode';
  FMode := TComboBox.Create(Self);
  FMode.Parent := Self;
  FMode.SetBounds(18, 36, 500, 28);
  FMode.Style := csDropDownList;
  FMode.Items.Add('Off');
  FMode.Items.Add('Image (JPG / PNG / BMP)');
  FMode.Items.Add('Video (MP4, always plays while typing)');
  FMode.ItemIndex := Ord(EditorWallpaper.Kind);
  FMode.OnChange := ModeChange;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(18, 72, 475, 20);
  L.Caption := 'Wallpaper file';
  FPath := TEdit.Create(Self);
  FPath.Parent := Self;
  FPath.SetBounds(18, 95, 390, 27);
  FPath.Text := EditorWallpaper.Path;
  FBrowse := TButton.Create(Self);
  FBrowse.Parent := Self;
  FBrowse.SetBounds(416, 94, 102, 29);
  FBrowse.Caption := 'Browse...';
  FBrowse.OnClick := BrowseClick;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(18, 135, 500, 20);
  L.Caption := 'Image strength / opacity';
  FOpacity := TTrackBar.Create(Self);
  FOpacity.Parent := Self;
  FOpacity.SetBounds(18, 154, 500, 34);
  FOpacity.Min := 0;
  FOpacity.Max := 255;
  FOpacity.Position := EditorWallpaper.Opacity;
  FOpacity.Frequency := 25;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(18, 193, 480, 20);
  L.Caption := 'Extra darkening (protect readability)';
  FDim := TTrackBar.Create(Self);
  FDim.Parent := Self;
  FDim.SetBounds(18, 211, 500, 34);
  FDim.Min := 0;
  FDim.Max := 220;
  FDim.Position := EditorWallpaper.Dim;
  FDim.Frequency := 20;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(18, 252, 500, 20);
  L.Caption := 'Background softening (0 = off, 3 = maximum)';
  FBlur := TTrackBar.Create(Self);
  FBlur.Parent := Self;
  FBlur.SetBounds(18, 270, 500, 34);
  FBlur.Min := 0;
  FBlur.Max := 3;
  FBlur.Position := EditorWallpaper.Blur;

  L := TLabel.Create(Self);
  L.Parent := Self;
  L.SetBounds(18, 312, 245, 20);
  L.Caption := 'MP4 playback quality / frame rate';
  FVideoFPS := TComboBox.Create(Self);
  FVideoFPS.Parent := Self;
  FVideoFPS.SetBounds(18, 334, 242, 28);
  FVideoFPS.Style := csDropDownList;
  FVideoFPS.Items.Add('Low (12 FPS)');
  FVideoFPS.Items.Add('Medium (24 FPS)');
  FVideoFPS.Items.Add('High (30 FPS)');
  case EditorWallpaper.FPS of
    12: FVideoFPS.ItemIndex := 0;
    30: FVideoFPS.ItemIndex := 2;
    else FVideoFPS.ItemIndex := 1;
  end;

  FDark := TCheckBox.Create(Self);
  FDark.Parent := Self;
  FDark.SetBounds(18, 377, 490, 26);
  FDark.Caption := 'Use black IDE theme';
  FDark.Checked := EditorWallpaper.DarkUI;
  L := TLabel.Create(Self);
  L.Parent := Self;
  FWholeApp := TCheckBox.Create(Self);
  FWholeApp.Parent := Self;
  FWholeApp.SetBounds(18, 407, 500, 27);
  FWholeApp.Caption := 'Wallpaper across workspace (tabs, sidebar, blank panels)';
  FWholeApp.Checked := EditorWallpaper.WholeApp;
  L.SetBounds(18, 435, 510, 22);
  L.Caption := 'Video keeps playing during typing; buttons stay dark for readability.';

  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(316, 469, 96, 32);
  B.Caption := 'Save';
  B.ModalResult := mrOk;
  B.Default := True;
  B := TButton.Create(Self);
  B.Parent := Self;
  B.SetBounds(422, 469, 96, 32);
  B.Caption := 'Cancel';
  B.ModalResult := mrCancel;
  B.Cancel := True;
  ModeChange(Self);
end;

procedure TWallpaperDialog.ModeChange(Sender: TObject);
begin
  FPath.Enabled := FMode.ItemIndex <> 0;
  FBrowse.Enabled := FMode.ItemIndex <> 0;
  FOpacity.Enabled := FMode.ItemIndex <> 0;
  FDim.Enabled := FMode.ItemIndex <> 0;
  FBlur.Enabled := FMode.ItemIndex <> 0;
  FVideoFPS.Enabled := FMode.ItemIndex = 2;
end;

procedure TWallpaperDialog.BrowseClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    if FMode.ItemIndex = 2 then
      D.Filter := 'MP4 video (*.mp4)|*.mp4'
    else
      D.Filter := 'Images (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp';
    D.FileName := FPath.Text;
    D.Options := [ofFileMustExist, ofPathMustExist];
    if D.Execute then FPath.Text := D.FileName;
  finally
    D.Free;
  end;
end;

function TWallpaperDialog.Confirm(out AKind: TWallpaperKind; out APath: string;
  out AOpacity, ADim, ABlur, AFPS: Integer;
  out ADark, AWholeApp: Boolean): Boolean;
const
  FPSValues: array[0..2] of Integer = (12, 24, 30);
begin
  Result := ShowModal = mrOk;
  if not Result then Exit;
  AKind := TWallpaperKind(FMode.ItemIndex);
  APath := Trim(FPath.Text);
  AOpacity := FOpacity.Position;
  ADim := FDim.Position;
  ABlur := FBlur.Position;
  AFPS := FPSValues[EnsureRange(FVideoFPS.ItemIndex, 0, 2)];
  ADark := FDark.Checked;
  AWholeApp := FWholeApp.Checked;
end;

function ShowEditorWallpaperSettings(AOwner: TComponent): Boolean;
var
  D: TWallpaperDialog;
  Kind: TWallpaperKind;
  Path: string;
  Opacity, DimAmount, BlurAmount, Rate: Integer;
  Dark, WholeApp: Boolean;
begin
  Result := False;
  D := TWallpaperDialog.CreateNew(AOwner);
  try
    if D.Confirm(Kind, Path, Opacity, DimAmount, BlurAmount, Rate, Dark, WholeApp) then
      Result := EditorWallpaper.Apply(Kind, Path, Opacity, Dark,
        DimAmount, BlurAmount, Rate, WholeApp);
  finally
    D.Free;
  end;
end;

initialization
  SharedWallpaper := nil;

finalization
  SharedWallpaper.Free;

end.
