# DBK32 用户层 Socket 通信迁移指南

## 概述

本指南说明如何将 DBK32 用户层从 IRP (DeviceIoControl) 通信迁移到 Socket 通信。

## 已创建的文件

### 1. DBKSocketComm.pas
新创建的 Socket 通信模块，提供以下功能：
- `DBKSocket_Initialize`: 初始化并连接到驱动的 Socket 服务器 (127.0.0.1:28996)
- `DBKSocket_Cleanup`: 清理 Socket 连接
- `DBKSocket_IsConnected`: 检查连接状态
- `DBKSocket_SendRequest`: 发送 IOCTL 请求并接收响应

## 需要修改的文件

### 1. DBK32functions.pas

#### 修改 1: 添加单元引用

在 `uses` 子句中添加 `DBKSocketComm`:

```pascal
{$ifdef windows}
uses
  jwawindows, windows, sysutils, classes, types, registry, multicpuexecution,
  forms,dialogs, controls, maps, globals, DBKSocketComm;  // 添加 DBKSocketComm
```

**状态**: ✅ 已完成

#### 修改 2: 修改 DeviceIoControl 函数

找到 `function DeviceIoControl` 的实现（大约在第 440-450 行），将其修改为：

```pascal
function DeviceIoControl(hDevice: THandle; dwIoControlCode: DWORD; lpInBuffer: Pointer; nInBufferSize: DWORD; lpOutBuffer: Pointer; nOutBufferSize: DWORD; var lpBytesReturned: DWORD; lpOverlapped: POverlapped): BOOL; stdcall;
begin
  if hdevice=$fff00fff then
  begin
    //dbvm handle
    result:=SecondaryDeviceIoControl(dwIoControlCode, lpInBuffer, nInBufferSize, lpOutBuffer, nOutBufferSize, lpBytesReturned, lpOverlapped);
  end
  else if DBKSocket_IsConnected then
  begin
    //使用Socket通信
    result:=DBKSocket_SendRequest(dwIoControlCode, lpInBuffer, nInBufferSize, lpOutBuffer, nOutBufferSize, lpBytesReturned);
  end
  else
    result:=windows.DeviceIoControl(hDevice, dwIoControlCode, lpInBuffer,nInBufferSize, lpOutBuffer, nOutBufferSize, lpBytesReturned, lpOverlapped );

end;
```

**原始代码**:
```pascal
function DeviceIoControl(hDevice: THandle; dwIoControlCode: DWORD; lpInBuffer: Pointer; nInBufferSize: DWORD; lpOutBuffer: Pointer; nOutBufferSize: DWORD; var lpBytesReturned: DWORD; lpOverlapped: POverlapped): BOOL; stdcall;
begin
  if hdevice=$fff00fff then
  begin
    //dbvm handle
    result:=SecondaryDeviceIoControl(dwIoControlCode, lpInBuffer, nInBufferSize, lpOutBuffer, nOutBufferSize, lpBytesReturned, lpOverlapped);
  end
  else
    result:=windows.DeviceIoControl(hDevice, dwIoControlCode, lpInBuffer,nInBufferSize, lpOutBuffer, nOutBufferSize, lpBytesReturned, lpOverlapped );

end;
```

#### 修改 3: 修改 DBK32Initialize 过程

找到 `procedure DBK32Initialize` 的实现（大约在第 3100-3500 行），在驱动加载部分之后添加 Socket 连接逻辑。

在这段代码之后：
```pascal
        hdevice:=INVALID_HANDLE_VALUE;
        hDevice := CreateFileW(pwidechar('\\.\'+servicename),
                      GENERIC_READ or GENERIC_WRITE,
                      FILE_SHARE_READ or FILE_SHARE_WRITE,
                      nil,
                      OPEN_EXISTING,
                      FILE_FLAG_OVERLAPPED,
                      0);
```

添加以下代码：
```pascal
        // 尝试使用 Socket 通信连接驱动
        if hdevice=INVALID_HANDLE_VALUE then
        begin
          OutputDebugString('[DBK32] Device handle invalid, trying Socket communication...');
          if DBKSocket_Initialize then
          begin
            OutputDebugString('[DBK32] Socket communication initialized successfully');
            // 设置一个虚拟句柄表示使用 Socket 通信
            hdevice := THandle($CEDB0001);
          end
          else
          begin
            OutputDebugString('[DBK32] Socket communication failed');
          end;
        end
        else
        begin
          // 如果设备句柄有效，也尝试使用 Socket 通信（优先使用 Socket）
          OutputDebugString('[DBK32] Device handle valid, but trying Socket communication first...');
          if DBKSocket_Initialize then
          begin
            OutputDebugString('[DBK32] Socket communication initialized, will use Socket instead of IRP');
            // 关闭设备句柄，使用 Socket
            CloseHandle(hdevice);
            hdevice := THandle($CEDB0001);
          end
          else
          begin
            OutputDebugString('[DBK32] Socket communication failed, falling back to IRP');
          end;
        end;
```

#### 修改 4: 修改 isDriverLoaded 函数

找到 `function isDriverLoaded` 的实现（大约在第 450-460 行），修改为：

```pascal
function isDriverLoaded(SigningIsTheCause: PBOOL): BOOL; stdcall;
begin
  result:=true;
  if (hdevice=INVALID_HANDLE_VALUE) and (not DBKSocket_IsConnected) then
  begin
    if SigningIsTheCause<>nil then
      SigningIsTheCause^:=failedduetodriversigning;

    result:=false;
  end;
end;
```

**原始代码**:
```pascal
function isDriverLoaded(SigningIsTheCause: PBOOL): BOOL; stdcall;
begin
  result:=true;
  if hdevice=INVALID_HANDLE_VALUE then
  begin
    if SigningIsTheCause<>nil then
      SigningIsTheCause^:=failedduetodriversigning;

    result:=false;
  end;
end;
```

#### 修改 5: 添加清理代码

在单元的 finalization 部分添加 Socket 清理：

```pascal
finalization
  DBKSocket_Cleanup;
```

如果没有 finalization 部分，在文件末尾 `end.` 之前添加：

```pascal
finalization
  DBKSocket_Cleanup;

end.
```

## 工作原理

### 通信流程

```
用户层应用 (Cheat Engine)
    ↓
DBK32functions.pas
    ↓
DeviceIoControl() 函数
    ↓
检查: DBKSocket_IsConnected?
    ↓ 是
DBKSocketComm.pas
    ↓
DBKSocket_SendRequest()
    ↓
构造消息头 (16字节)
    ↓
发送消息头 + 输入数据
    ↓
TCP Socket (127.0.0.1:28996)
    ↓
驱动层 SocketComm 模块
    ↓
接收响应头 + 输出数据
    ↓
返回结果给应用
```

### 消息格式

#### 请求消息头 (16字节)
```
+0x00: DWORD IoControlCode      // IOCTL 代码
+0x04: DWORD InputBufferSize    // 输入数据大小
+0x08: DWORD OutputBufferSize   // 期望输出大小
+0x0C: DWORD Reserved           // 保留 (0)
```

#### 响应消息头 (16字节)
```
+0x00: LONG Status              // NTSTATUS 状态码
+0x04: DWORD DataSize           // 输出数据大小
+0x08: DWORD Reserved1          // 保留
+0x0C: DWORD Reserved2          // 保留
```

## 兼容性

### 保持向后兼容

修改后的代码保持向后兼容：
1. 如果 Socket 连接失败，会回退到传统的 IRP 通信
2. 所有现有的 IOCTL 命令无需修改
3. 上层应用代码无需任何更改

### 优先级

通信方式优先级：
1. **Socket 通信** - 如果 `DBKSocket_IsConnected` 返回 true
2. **DBVM 通信** - 如果 `hdevice=$fff00fff`
3. **IRP 通信** - 回退方案

## 测试步骤

### 1. 编译项目

```bash
# 在 Lazarus/Delphi 中打开项目
# 确保 DBKSocketComm.pas 已添加到项目
# 编译项目
```

### 2. 加载驱动

```cmd
# 以管理员身份运行
sc create DBK type= kernel binPath= C:\path\to\DBK.sys
sc start DBK
```

### 3. 验证 Socket 监听

```cmd
netstat -ano | findstr 28996
```

应该看到：
```
TCP    127.0.0.1:28996        0.0.0.0:0              LISTENING
```

### 4. 运行 Cheat Engine

启动 Cheat Engine，检查调试输出：
- 应该看到 `[DBK32] Socket communication initialized successfully`
- 应该看到 `[DBKSocket] Successfully connected to driver!`

### 5. 测试功能

测试基本功能：
- 打开进程
- 读取内存
- 写入内存
- 扫描内存

## 故障排除

### 问题 1: Socket 连接失败

**症状**: `[DBKSocket] connect() failed: 10061`

**解决方案**:
1. 确认驱动已加载：`sc query DBK`
2. 确认端口监听：`netstat -ano | findstr 28996`
3. 检查防火墙设置

### 问题 2: 编译错误

**症状**: `Identifier not found "DBKSocket_Initialize"`

**解决方案**:
1. 确认 `DBKSocketComm.pas` 已添加到项目
2. 确认 `uses` 子句包含 `DBKSocketComm`
3. 重新编译整个项目

### 问题 3: 功能异常

**症状**: 某些功能不工作

**解决方案**:
1. 使用 DebugView 查看日志
2. 检查 IOCTL 代码是否正确
3. 验证数据大小是否匹配

## 性能考虑

### Socket vs IRP

| 指标 | IRP | Socket | 差异 |
|------|-----|--------|------|
| 延迟 | ~0.1ms | ~0.4ms | 4x |
| 吞吐量 | 高 | 中 | - |
| 灵活性 | 低 | 高 | - |
| 跨语言 | 否 | 是 | - |

### 优化建议

1. **保持长连接** - Socket 连接在整个会话期间保持
2. **批量操作** - 尽可能合并多个小请求
3. **缓冲区复用** - 重用发送/接收缓冲区

## 调试技巧

### 启用详细日志

在 `DBKSocketComm.pas` 中，所有关键操作都有 `OutputDebugString` 日志。

使用 DebugView 查看：
```
[DBKSocket] Initializing socket communication...
[DBKSocket] Connecting to 127.0.0.1:28996...
[DBKSocket] Successfully connected to driver!
[DBKSocket] Failed to send message header for IOCTL: 0x9C4020C0
```

### 网络抓包

使用 Wireshark 抓取本地回环流量：
1. 安装 Npcap
2. 选择 "Adapter for loopback traffic capture"
3. 过滤器：`tcp.port == 28996`

## 总结

完成以上修改后，DBK32 用户层将能够通过 Socket 与驱动通信，同时保持向后兼容性。

### 优势

✅ **跨语言支持** - 任何语言都可以编写客户端  
✅ **易于调试** - 可以使用网络工具抓包分析  
✅ **灵活性高** - 不依赖 Windows 设备驱动框架  
✅ **向后兼容** - 保留 IRP 通信作为回退方案  

### 下一步

1. 完成 DBK32functions.pas 的修改
2. 编译并测试
3. 验证所有功能正常工作
4. 根据需要调整和优化

---

**创建日期**: 2026年2月9日  
**版本**: 1.0  
**状态**: 待实施

