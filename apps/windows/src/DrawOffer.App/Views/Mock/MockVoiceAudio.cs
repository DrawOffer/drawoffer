using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using DrawOffer.Core.Session;
using Windows.Devices.Enumeration;
using Windows.Media;
using Windows.Media.Audio;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.Render;
using Windows.Storage.Streams;

namespace DrawOffer.App.Views;

/// <summary>内存中的系统麦克风采集；AudioGraph 转换为 16 kHz / mono / PCM16，网络发送严格串行。</summary>
internal sealed class MockVoiceRecorder : IDisposable
{
    [ComImport, Guid("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMemoryBufferByteAccess { void GetBuffer(out IntPtr buffer, out uint capacity); }
    internal sealed record Final(string SessionId, string Text, int DurationMs);
    AudioGraph? _graph;
    AudioDeviceInputNode? _input;
    AudioFrameOutputNode? _output;
    ClientWebSocket? _socket;
    CancellationTokenSource? _life;
    Channel<byte[]>? _frames;
    Task? _sender;
    TaskCompletionSource<Final>? _final;
    int _pendingBytes;
    public bool Recording { get; private set; }
    public string Partial { get; private set; } = "";
    public double Level { get; private set; }
    public event Action? Changed;
    public event Action<string>? Failed;

    public static async Task<IReadOnlyList<DeviceInformation>> DevicesAsync() => (await DeviceInformation.FindAllAsync(DeviceClass.AudioCapture)).ToList();

    public async Task StartAsync(SessionCoordinator api, string interview, string question, string purpose, string? deviceId, CancellationToken ct)
    {
        Cancel();
        var life = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _life = life;
        var token = life.Token;
        Partial = ""; Level = 0;
        _final = new(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            // MediaCapture requests the Windows microphone privacy permission before AudioGraph opens a device.
            using (var permission = new MediaCapture())
                await permission.InitializeAsync(new MediaCaptureInitializationSettings { StreamingCaptureMode = StreamingCaptureMode.Audio, AudioDeviceId = deviceId ?? "" });
            token.ThrowIfCancellationRequested();
            var graphResult = await AudioGraph.CreateAsync(new AudioGraphSettings(AudioRenderCategory.Speech)
            {
                EncodingProperties = AudioEncodingProperties.CreatePcm(16000, 1, 16),
                QuantumSizeSelectionMode = QuantumSizeSelectionMode.ClosestToDesired,
                DesiredSamplesPerQuantum = 1600,
            });
            if (graphResult.Status != AudioGraphCreationStatus.Success) throw new IOException("无法初始化系统音频：" + graphResult.Status);
            var graph = graphResult.Graph;
            if (token.IsCancellationRequested) { graph.Dispose(); token.ThrowIfCancellationRequested(); }
            _graph = graph;
            var device = deviceId is null ? null : await DeviceInformation.CreateFromIdAsync(deviceId);
            var inputResult = await graph.CreateDeviceInputNodeAsync(MediaCategory.Speech, graph.EncodingProperties, device);
            if (inputResult.Status != AudioDeviceNodeCreationStatus.Success) throw new IOException("麦克风不可用：" + inputResult.Status);
            if (token.IsCancellationRequested) { inputResult.DeviceInputNode.Dispose(); token.ThrowIfCancellationRequested(); }
            _input = inputResult.DeviceInputNode;
            _output = graph.CreateFrameOutputNode(AudioEncodingProperties.CreatePcm(16000, 1, 16));
            _input.AddOutgoingConnection(_output);
            _socket = await api.SpeechSocketAsync(interview, question, purpose, token);
            token.ThrowIfCancellationRequested();
            _frames = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(320) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
            var socket = _socket;
            var frames = _frames;
            var final = _final;
            _sender = SendAsync(socket, frames, token);
            _ = ReceiveAsync(socket, final, token);
            Recording = true;
            graph.QuantumProcessed += QuantumProcessed;
            graph.Start();
            Changed?.Invoke();
        }
        catch
        {
            Cancel();
            throw;
        }
    }

    void QuantumProcessed(AudioGraph sender, object args)
    {
        if (!Recording || _output is null || _frames is null) return;
        try
        {
            using var frame = _output.GetFrame();
            using var buffer = frame.LockBuffer(AudioBufferAccessMode.Read);
            using var reference = buffer.CreateReference();
            ((IMemoryBufferByteAccess)reference).GetBuffer(out var pointer, out var capacity);
            var length = (int)Math.Min(buffer.Length, capacity);
            if (length == 0) return;
            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            double square = 0;
            for (var i = 0; i + 1 < bytes.Length; i += 2) { var sample = (short)(bytes[i] | bytes[i + 1] << 8) / 32768.0; square += sample * sample; }
            Level = Math.Min(1, Math.Sqrt(square / Math.Max(1, bytes.Length / 2)) * 4);
            if (Interlocked.Add(ref _pendingBytes, length) > 1024 * 1024 || !_frames.Writer.TryWrite(bytes))
            { Interlocked.Add(ref _pendingBytes, -length); Fail("网络太慢，录音没能及时发送，请重新录音。"); return; }
            Changed?.Invoke();
        }
        catch (Exception ex) { Fail("录音中断：" + ex.Message); }
    }

    async Task SendAsync(ClientWebSocket socket, Channel<byte[]> frames, CancellationToken ct)
    {
        try
        {
            await foreach (var bytes in frames.Reader.ReadAllAsync(ct))
            {
                await socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Binary, true, ct);
                Interlocked.Add(ref _pendingBytes, -bytes.Length);
            }
        }
        catch (OperationCanceledException) { }
        catch { Fail("语音识别连接中断，请重新录音。"); }
    }

    async Task ReceiveAsync(ClientWebSocket socket, TaskCompletionSource<Final> final, CancellationToken ct)
    {
        try
        {
            var chunk = new byte[8192];
            while (!ct.IsCancellationRequested)
            {
                using var message = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(new ArraySegment<byte>(chunk), ct);
                    if (result.MessageType == WebSocketMessageType.Close)
                        throw new IOException((int?)socket.CloseStatus == 4401 ? "登录已失效，请重新登录。" : (int?)socket.CloseStatus == 4409 ? "面试状态已变化，请重新加载场次。" : "语音识别连接中断，请重新录音。");
                    if (message.Length + result.Count > 1024 * 1024) throw new IOException("识别响应过大。");
                    message.Write(chunk, 0, result.Count);
                } while (!result.EndOfMessage);
                if (result.MessageType != WebSocketMessageType.Text) continue;
                var data = JsonNode.Parse(message.ToArray());
                switch (data?["type"]?.GetValue<string>())
                {
                    case "partial": Partial = data?["text"]?.GetValue<string>() ?? ""; Changed?.Invoke(); break;
                    case "final":
                        var value = new Final(data?["session_id"]?.GetValue<string>() ?? "", data?["text"]?.GetValue<string>() ?? "", data?["duration_ms"]?.GetValue<int>() ?? 0);
                        Partial = value.Text;
                        StopCapture();
                        final.TrySetResult(value);
                        Changed?.Invoke();
                        return;
                    case "error": throw new IOException("语音识别失败（" + data?["code"]?.GetValue<string>() + "），请重新录音。");
                }
            }
        }
        catch (OperationCanceledException) { final.TrySetCanceled(); }
        catch (Exception ex) { final.TrySetException(ex); if (!ct.IsCancellationRequested) Fail(ex.Message); }
    }

    public async Task<Final> StopAsync(CancellationToken ct)
    {
        var socket = _socket ?? throw new IOException("录音尚未开始。");
        var final = _final ?? throw new IOException("录音尚未开始。");
        StopCapture();
        _frames?.Writer.TryComplete();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            if (_sender is not null) await _sender.WaitAsync(timeout.Token);
            if (!final.Task.IsCompleted) await socket.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes("{\"type\":\"stop\"}")), WebSocketMessageType.Text, true, timeout.Token);
            return await final.Task.WaitAsync(timeout.Token);
        }
        finally { Cancel(); }
    }

    void Fail(string text)
    {
        _final?.TrySetException(new IOException(text));
        Recording = false;
        _life?.Cancel();
        // Do not dispose AudioGraph in its realtime callback. UI owner cancels/disposes after this notification.
        Failed?.Invoke(text);
    }
    void StopCapture()
    {
        Recording = false;
        if (_graph is { } graph) { graph.QuantumProcessed -= QuantumProcessed; graph.Stop(); }
        Level = 0;
    }
    public void Cancel()
    {
        StopCapture();
        _frames?.Writer.TryComplete(); _frames = null;
        _life?.Cancel(); _life?.Dispose(); _life = null;
        _socket?.Abort(); _socket?.Dispose(); _socket = null;
        _input?.Dispose(); _input = null; _output?.Dispose(); _output = null;
        _graph?.Dispose(); _graph = null;
        _final?.TrySetCanceled(); _final = null;
        _pendingBytes = 0;
    }
    public void Dispose() => Cancel();
}

/// <summary>面试官 MP3 按 seq 排队，内存播放；离开页面立即停止并释放流。</summary>
internal sealed class MockVoicePlayer : IDisposable
{
    readonly MediaPlayer _player = new() { AutoPlay = false };
    readonly Queue<byte[]> _queue = new();
    readonly Microsoft.UI.Dispatching.DispatcherQueue _dispatcher;
    InMemoryRandomAccessStream? _stream;
    MediaSource? _source;
    public bool Playing { get; private set; }
    public event Action? Changed;
    public event Action? Failed;
    public MockVoicePlayer(Microsoft.UI.Dispatching.DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        _player.MediaEnded += (_, _) => _dispatcher.TryEnqueue(Next);
        _player.MediaFailed += (_, _) => _dispatcher.TryEnqueue(() => { Failed?.Invoke(); Next(); });
    }
    public void Enqueue(IEnumerable<JsonNode?> events)
    {
        foreach (var e in events.Where(e => e?["event"]?.GetValue<string>() == "interviewer.audio").OrderBy(e => e?["data"]?["seq"]?.GetValue<int>() ?? 0))
            try { _queue.Enqueue(Convert.FromBase64String(e?["data"]?["data"]?.GetValue<string>() ?? "")); } catch (FormatException) { Failed?.Invoke(); }
        if (!Playing) Next();
    }
    public void Play(byte[] bytes) { _queue.Enqueue(bytes); if (!Playing) Next(); }
    int _generation;
    async void Next()
    {
        var generation = ++_generation;
        _player.Source = null; _source?.Dispose(); _source = null; _stream?.Dispose(); _stream = null;
        if (_queue.Count == 0) { Playing = false; Changed?.Invoke(); return; }
        Playing = true;
        try
        {
            var stream = new InMemoryRandomAccessStream();
            _stream = stream;
            var bytes = _queue.Dequeue();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            { writer.WriteBytes(bytes); await writer.StoreAsync(); writer.DetachStream(); }
            if (generation != _generation) return;
            stream.Seek(0);
            _source = MediaSource.CreateFromStream(stream, "audio/mpeg");
            _player.Source = _source; _player.Play(); Changed?.Invoke();
        }
        catch { if (generation == _generation) { Playing = false; Failed?.Invoke(); Next(); } }
    }
    public void Stop() { ++_generation; _queue.Clear(); _player.Pause(); _player.Source = null; _source?.Dispose(); _source = null; _stream?.Dispose(); _stream = null; Playing = false; Changed?.Invoke(); }
    public void Dispose() { Stop(); _player.Dispose(); }
}
