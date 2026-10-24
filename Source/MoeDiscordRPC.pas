unit MoeDiscordRPC;

interface

uses
  Winapi.Windows, System.Classes, System.SysUtils, System.SyncObjs;

type
  TMoeDiscordRPC = class(TThread)
  private
    FLock: TCriticalSection;
    FEnabled: Boolean;
    FClientId, FDetails, FState: string;
    FStarted: Int64;
    procedure Snapshot(out Enabled: Boolean; out ClientId, Details, State: string);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(AEnabled: Boolean; const AClientId: string);
    procedure UpdateActivity(const ADetails, AState: string);
  end;

implementation

uses
  System.JSON, System.DateUtils, System.IOUtils;

procedure RPCTrace(const Text: string);
var
  Target: string;
begin
  Target := GetEnvironmentVariable('MOE_RPC_TRACE');
  if Target = '' then Exit;
  try
    TFile.AppendAllText(Target, Text + sLineBreak);
  except
    // Diagnostics must never interfere with the editor.
  end;
end;

function SendFrame(Pipe: THandle; Opcode: Cardinal; const Text: string): Boolean;
var
  Data, Packet: TBytes;
  Size, Count: Cardinal;
begin
  Result := False;
  Data := TEncoding.UTF8.GetBytes(Text);
  Size := Length(Data);
  if Size > 32768 then Exit;
  SetLength(Packet, Size + 8);
  Move(Opcode, Packet[0], 4);
  Move(Size, Packet[4], 4);
  if Size <> 0 then Move(Data[0], Packet[8], Size);
  Result := WriteFile(Pipe, Packet[0], Length(Packet), Count, nil) and
    (Count = Cardinal(Length(Packet)));
end;

function ReceiveFrame(Pipe: THandle; out Opcode: Cardinal; out Text: string;
  Timeout: Cardinal): Boolean;
var
  Available, ReadCount, Size: Cardinal;
  Header: array[0..7] of Byte;
  Data: TBytes;
  Started: Cardinal;
begin
  Result := False;
  Text := '';
  Started := GetTickCount;
  repeat
    if not PeekNamedPipe(Pipe, nil, 0, nil, @Available, nil) then Exit;
    if Available >= 8 then
    begin
      if not PeekNamedPipe(Pipe, @Header[0], 8, @ReadCount, nil, nil) or
         (ReadCount <> 8) then Exit;
      Move(Header[0], Opcode, 4);
      Move(Header[4], Size, 4);
      if Size > 65536 then Exit;
      if Available >= Size + 8 then
      begin
        if not ReadFile(Pipe, Header[0], 8, ReadCount, nil) or
           (ReadCount <> 8) then Exit;
        SetLength(Data, Size);
        if Size > 0 then
        begin
          if not ReadFile(Pipe, Data[0], Size, ReadCount, nil) or
             (ReadCount <> Size) then Exit;
          Text := TEncoding.UTF8.GetString(Data);
        end;
        Exit(True);
      end;
    end;
    Sleep(40);
  until (GetTickCount - Started >= Timeout);
end;

function IsReady(const Payload: string): Boolean;
var
  Json: TJSONValue;
begin
  Result := False;
  Json := TJSONObject.ParseJSONValue(Payload);
  try
    if Json is TJSONObject then
      Result := SameText(TJSONObject(Json).GetValue<string>('evt', ''), 'READY');
  finally
    Json.Free;
  end;
end;

function JsonActivity(const Details, State: string; Started: Int64): string;
var
  Root, Args, Activity, Timestamps: TJSONObject;
  Nonce: TGUID;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('cmd', 'SET_ACTIVITY');
    CreateGUID(Nonce);
    Root.AddPair('nonce', Copy(GUIDToString(Nonce), 2, 36));
    Args := TJSONObject.Create;
    Root.AddPair('args', Args);
    Args.AddPair('pid', TJSONNumber.Create(GetCurrentProcessId));
    Activity := TJSONObject.Create;
    Args.AddPair('activity', Activity);
    Activity.AddPair('type', TJSONNumber.Create(0));
    Activity.AddPair('details', Copy(Details, 1, 120));
    Activity.AddPair('state', Copy(State, 1, 120));
    Timestamps := TJSONObject.Create;
    Activity.AddPair('timestamps', Timestamps);
    Timestamps.AddPair('start', TJSONNumber.Create(Started));
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

constructor TMoeDiscordRPC.Create;
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FStarted := DateTimeToUnix(Now, False);
  FDetails := 'Idle in Moe C++';
  FState := 'No project open';
end;

destructor TMoeDiscordRPC.Destroy;
begin
  Terminate;
  WaitFor;
  FLock.Free;
  inherited Destroy;
end;

procedure TMoeDiscordRPC.Configure(AEnabled: Boolean; const AClientId: string);
begin
  FLock.Enter;
  try
    FEnabled := AEnabled and (Trim(AClientId) <> '');
    FClientId := Trim(AClientId);
  finally
    FLock.Leave;
  end;
end;

procedure TMoeDiscordRPC.UpdateActivity(const ADetails, AState: string);
begin
  FLock.Enter;
  try
    FDetails := ADetails;
    FState := AState;
  finally
    FLock.Leave;
  end;
end;

procedure TMoeDiscordRPC.Snapshot(out Enabled: Boolean;
  out ClientId, Details, State: string);
begin
  FLock.Enter;
  try
    Enabled := FEnabled;
    ClientId := FClientId;
    Details := FDetails;
    State := FState;
  finally
    FLock.Leave;
  end;
end;

procedure TMoeDiscordRPC.Execute;
var
  Pipe: THandle;
  I, Opcode: Cardinal;
  Enabled: Boolean;
  ClientId, Details, State, Previous, Payload, Response, ConnectedId: string;
  Handshake: TJSONObject;
  NextAttempt, LastPublish: Cardinal;
begin
  Pipe := INVALID_HANDLE_VALUE;
  ConnectedId := '';
  Previous := '';
  NextAttempt := 0;
  LastPublish := 0;
  try
    while not Terminated do
    begin
      Snapshot(Enabled, ClientId, Details, State);
      if (not Enabled) or (ConnectedId <> ClientId) then
      begin
        if Pipe <> INVALID_HANDLE_VALUE then
        begin
          if not Enabled then
            SendFrame(Pipe, 1, Format('{"cmd":"SET_ACTIVITY","args":{"pid":%d,"activity":null}}',
              [GetCurrentProcessId]));
          CloseHandle(Pipe);
        end;
        Pipe := INVALID_HANDLE_VALUE;
        ConnectedId := '';
        Previous := '';
      end;
      if Enabled and (Pipe = INVALID_HANDLE_VALUE) and
         (GetTickCount - NextAttempt >= 3000) then
      begin
        NextAttempt := GetTickCount;
        for I := 0 to 9 do
        begin
          if Terminated then Break;
          Pipe := CreateFile(PChar('\\.\pipe\discord-ipc-' + IntToStr(I)),
            GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
          if Pipe = INVALID_HANDLE_VALUE then Continue;
          Handshake := TJSONObject.Create;
          try
            Handshake.AddPair('v', TJSONNumber.Create(1));
            Handshake.AddPair('client_id', ClientId);
            Payload := Handshake.ToJSON;
          finally
            Handshake.Free;
          end;
          if not SendFrame(Pipe, 0, Payload) then
          begin
            RPCTrace('Handshake WriteFile failed: ' + IntToStr(GetLastError));
          end
          else
          begin
            RPCTrace('Handshake sent to index ' + IntToStr(I));
            if ReceiveFrame(Pipe, Opcode, Payload, 8000) then
            begin
              RPCTrace('Handshake response opcode=' + IntToStr(Opcode) +
                ' payload=' + Copy(Payload, 1, 80));
              if (Opcode = 1) and IsReady(Payload) then
              begin
                ConnectedId := ClientId;
                LastPublish := 0;
                Break;
              end;
            end
            else
              RPCTrace('Handshake ReceiveFrame failed: ' + IntToStr(GetLastError));
          end;
          CloseHandle(Pipe);
          Pipe := INVALID_HANDLE_VALUE;
        end;
      end;
      if Pipe <> INVALID_HANDLE_VALUE then
      begin
        Payload := Details + #0 + State;
        if (Payload <> Previous) or (GetTickCount - LastPublish > 30000) then
        begin
          Response := JsonActivity(Details, State, FStarted);
          if not SendFrame(Pipe, 1, Response) then
          begin
            RPCTrace('Activity send failed: ' + IntToStr(GetLastError));
            CloseHandle(Pipe);
            Pipe := INVALID_HANDLE_VALUE;
            ConnectedId := '';
          end
          else
          begin
            RPCTrace('Activity sent: ' + Response);
            if ReceiveFrame(Pipe, Opcode, Response, 1200) then
              RPCTrace('Activity response opcode=' + IntToStr(Opcode) +
                ' payload=' + Copy(Response, 1, 360))
            else
              RPCTrace('Activity response not received within 1200ms');
            Previous := Payload;
            LastPublish := GetTickCount;
          end;
        end;
      end;
      for I := 1 to 5 do
      begin
        if Terminated then Break;
        Sleep(100);
      end;
    end;
  finally
    if Pipe <> INVALID_HANDLE_VALUE then
    begin
      SendFrame(Pipe, 1, Format('{"cmd":"SET_ACTIVITY","args":{"pid":%d,"activity":null}}',
        [GetCurrentProcessId]));
      CloseHandle(Pipe);
    end;
  end;
end;

end.
