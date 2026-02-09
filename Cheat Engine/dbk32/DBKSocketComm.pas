unit DBKSocketComm;

{$MODE Delphi}

interface

uses
  Windows, SysUtils, WinSock2;

const
  SOCKET_SERVER_HOST = '127.0.0.1';
  SOCKET_SERVER_PORT = 28996;

type
  // Socket消息头结构 (16字节)
  TSocketMessageHeader = packed record
    IoControlCode: DWORD;      // IOCTL代码 (4字节)
    InputBufferSize: DWORD;    // 输入数据大小 (4字节)
    OutputBufferSize: DWORD;   // 期望输出大小 (4字节)
    Reserved: DWORD;           // 保留字段 (4字节)
  end;
  PSocketMessageHeader = ^TSocketMessageHeader;

  // Socket响应头结构 (16字节)
  TSocketResponseHeader = packed record
    Status: LONG;              // NTSTATUS状态码 (4字节)
    DataSize: DWORD;           // 返回数据大小 (4字节)
    Reserved1: DWORD;          // 保留字段 (4字节)
    Reserved2: DWORD;          // 保留字段 (4字节)
  end;
  PSocketResponseHeader = ^TSocketResponseHeader;

// Socket通信函数
function DBKSocket_Initialize: Boolean;
procedure DBKSocket_Cleanup;
function DBKSocket_IsConnected: Boolean;
function DBKSocket_SendRequest(
  IoControlCode: DWORD;
  lpInBuffer: Pointer;
  nInBufferSize: DWORD;
  lpOutBuffer: Pointer;
  nOutBufferSize: DWORD;
  var lpBytesReturned: DWORD
): Boolean;

implementation

var
  g_Socket: TSocket = INVALID_SOCKET;
  g_WSAInitialized: Boolean = False;
  g_LastError: Integer = 0;

// 初始化WinSock
function InitializeWinSock: Boolean;
var
  WSAData: TWSAData;
begin
  Result := False;
  if g_WSAInitialized then
  begin
    Result := True;
    Exit;
  end;

  if WSAStartup(MAKEWORD(2, 2), WSAData) = 0 then
  begin
    g_WSAInitialized := True;
    Result := True;
  end
  else
  begin
    g_LastError := WSAGetLastError;
    OutputDebugString(PChar('[DBKSocket] WSAStartup failed: ' + IntToStr(g_LastError)));
  end;
end;

// 清理WinSock
procedure CleanupWinSock;
begin
  if g_WSAInitialized then
  begin
    WSACleanup;
    g_WSAInitialized := False;
  end;
end;

// 发送指定大小的数据（确保全部发送）
function SendExact(Socket: TSocket; Buffer: Pointer; Size: Integer): Boolean;
var
  TotalSent: Integer;
  BytesSent: Integer;
  P: PByte;
begin
  Result := False;
  TotalSent := 0;
  P := PByte(Buffer);

  while TotalSent < Size do
  begin
    BytesSent := send(Socket, P^, Size - TotalSent, 0);
    if BytesSent = SOCKET_ERROR then
    begin
      g_LastError := WSAGetLastError;
      OutputDebugString(PChar('[DBKSocket] send failed: ' + IntToStr(g_LastError)));
      Exit;
    end;

    Inc(TotalSent, BytesSent);
    Inc(P, BytesSent);
  end;

  Result := True;
end;

// 接收指定大小的数据（确保全部接收）
function RecvExact(Socket: TSocket; Buffer: Pointer; Size: Integer): Boolean;
var
  TotalReceived: Integer;
  BytesReceived: Integer;
  P: PByte;
begin
  Result := False;
  TotalReceived := 0;
  P := PByte(Buffer);

  while TotalReceived < Size do
  begin
    BytesReceived := recv(Socket, P^, Size - TotalReceived, 0);
    if BytesReceived = SOCKET_ERROR then
    begin
      g_LastError := WSAGetLastError;
      OutputDebugString(PChar('[DBKSocket] recv failed: ' + IntToStr(g_LastError)));
      Exit;
    end
    else if BytesReceived = 0 then
    begin
      OutputDebugString('[DBKSocket] Connection closed by remote host');
      Exit;
    end;

    Inc(TotalReceived, BytesReceived);
    Inc(P, BytesReceived);
  end;

  Result := True;
end;

// 初始化Socket连接
function DBKSocket_Initialize: Boolean;
var
  SockAddr: TSockAddrIn;
  ConnectResult: Integer;
begin
  Result := False;

  OutputDebugString('[DBKSocket] Initializing socket communication...');

  // 初始化WinSock
  if not InitializeWinSock then
  begin
    OutputDebugString('[DBKSocket] Failed to initialize WinSock');
    Exit;
  end;

  // 如果已经连接，先关闭
  if g_Socket <> INVALID_SOCKET then
  begin
    closesocket(g_Socket);
    g_Socket := INVALID_SOCKET;
  end;

  // 创建TCP Socket
  g_Socket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if g_Socket = INVALID_SOCKET then
  begin
    g_LastError := WSAGetLastError;
    OutputDebugString(PChar('[DBKSocket] socket() failed: ' + IntToStr(g_LastError)));
    Exit;
  end;

  // 设置Socket选项 - 禁用Nagle算法以减少延迟
  var NoDelay: Integer := 1;
  setsockopt(g_Socket, IPPROTO_TCP, TCP_NODELAY, @NoDelay, SizeOf(NoDelay));

  // 设置接收超时（5秒）
  var Timeout: Integer := 5000;
  setsockopt(g_Socket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));

  // 连接到驱动
  ZeroMemory(@SockAddr, SizeOf(SockAddr));
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := htons(SOCKET_SERVER_PORT);
  SockAddr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(SOCKET_SERVER_HOST)));

  OutputDebugString(PChar('[DBKSocket] Connecting to ' + SOCKET_SERVER_HOST + ':' + IntToStr(SOCKET_SERVER_PORT) + '...'));

  ConnectResult := WinSock2.connect(g_Socket, @SockAddr, SizeOf(SockAddr));
  if ConnectResult = SOCKET_ERROR then
  begin
    g_LastError := WSAGetLastError;
    OutputDebugString(PChar('[DBKSocket] connect() failed: ' + IntToStr(g_LastError)));
    closesocket(g_Socket);
    g_Socket := INVALID_SOCKET;
    Exit;
  end;

  OutputDebugString('[DBKSocket] Successfully connected to driver!');
  Result := True;
end;

// 清理Socket连接
procedure DBKSocket_Cleanup;
begin
  OutputDebugString('[DBKSocket] Cleaning up socket communication...');

  if g_Socket <> INVALID_SOCKET then
  begin
    closesocket(g_Socket);
    g_Socket := INVALID_SOCKET;
  end;

  CleanupWinSock;
end;

// 检查是否已连接
function DBKSocket_IsConnected: Boolean;
begin
  Result := (g_Socket <> INVALID_SOCKET);
end;

// 发送请求并接收响应
function DBKSocket_SendRequest(
  IoControlCode: DWORD;
  lpInBuffer: Pointer;
  nInBufferSize: DWORD;
  lpOutBuffer: Pointer;
  nOutBufferSize: DWORD;
  var lpBytesReturned: DWORD
): Boolean;
var
  MsgHeader: TSocketMessageHeader;
  RespHeader: TSocketResponseHeader;
begin
  Result := False;
  lpBytesReturned := 0;

  // 检查连接状态
  if g_Socket = INVALID_SOCKET then
  begin
    OutputDebugString('[DBKSocket] Not connected to driver');
    SetLastError(ERROR_NOT_CONNECTED);
    Exit;
  end;

  // 构造消息头
  ZeroMemory(@MsgHeader, SizeOf(MsgHeader));
  MsgHeader.IoControlCode := IoControlCode;
  MsgHeader.InputBufferSize := nInBufferSize;
  MsgHeader.OutputBufferSize := nOutBufferSize;
  MsgHeader.Reserved := 0;

  // 发送消息头
  if not SendExact(g_Socket, @MsgHeader, SizeOf(MsgHeader)) then
  begin
    OutputDebugString(PChar('[DBKSocket] Failed to send message header for IOCTL: 0x' + IntToHex(IoControlCode, 8)));
    Exit;
  end;

  // 发送输入数据（如果有）
  if (nInBufferSize > 0) and (lpInBuffer <> nil) then
  begin
    if not SendExact(g_Socket, lpInBuffer, nInBufferSize) then
    begin
      OutputDebugString('[DBKSocket] Failed to send input data');
      Exit;
    end;
  end;

  // 接收响应头
  if not RecvExact(g_Socket, @RespHeader, SizeOf(RespHeader)) then
  begin
    OutputDebugString('[DBKSocket] Failed to receive response header');
    Exit;
  end;

  // 检查状态码
  if RespHeader.Status <> 0 then
  begin
    OutputDebugString(PChar('[DBKSocket] Driver returned error status: 0x' + IntToHex(DWORD(RespHeader.Status), 8)));
    SetLastError(ERROR_INVALID_FUNCTION);
    Exit;
  end;

  // 接收输出数据（如果有）
  if RespHeader.DataSize > 0 then
  begin
    if lpOutBuffer = nil then
    begin
      OutputDebugString('[DBKSocket] Output buffer is nil but driver returned data');
      Exit;
    end;

    if RespHeader.DataSize > nOutBufferSize then
    begin
      OutputDebugString(PChar('[DBKSocket] Output buffer too small: need ' + IntToStr(RespHeader.DataSize) + ', have ' + IntToStr(nOutBufferSize)));
      Exit;
    end;

    if not RecvExact(g_Socket, lpOutBuffer, RespHeader.DataSize) then
    begin
      OutputDebugString('[DBKSocket] Failed to receive output data');
      Exit;
    end;

    lpBytesReturned := RespHeader.DataSize;
  end;

  Result := True;
end;

initialization
  g_Socket := INVALID_SOCKET;
  g_WSAInitialized := False;

finalization
  DBKSocket_Cleanup;

end.

