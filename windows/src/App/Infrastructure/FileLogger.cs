using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Minimal file logger writing to <c>%LOCALAPPDATA%\DemoTape\logs\demotape-*.log</c>.
/// The Windows analogue of the macOS <c>Log</c> helper — for diagnosing capture/encode issues
/// on runs launched outside a debugger.
/// </summary>
public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly string _logFile;
    private readonly BlockingCollection<string> _queue = new();
    private readonly Task _writer;

    public FileLoggerProvider(string logDirectory)
    {
        Directory.CreateDirectory(logDirectory);
        _logFile = Path.Combine(logDirectory, $"demotape-{DateTime.Now:yyyyMMdd}.log");
        _writer = Task.Run(WriteLoop);
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(categoryName, _queue);

    private void WriteLoop()
    {
        foreach (var line in _queue.GetConsumingEnumerable())
        {
            try { File.AppendAllText(_logFile, line + Environment.NewLine); }
            catch { /* best effort */ }
        }
    }

    public void Dispose()
    {
        _queue.CompleteAdding();
        try { _writer.Wait(TimeSpan.FromSeconds(2)); } catch { }
        _queue.Dispose();
    }

    private sealed class FileLogger : ILogger
    {
        private readonly string _category;
        private readonly BlockingCollection<string> _queue;

        public FileLogger(string category, BlockingCollection<string> queue)
        {
            _category = category;
            _queue = queue;
        }

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            var msg = formatter(state, exception);
            var line = $"[{DateTimeOffset.Now:O}] {logLevel,-11} {_category}: {msg}";
            if (exception is not null) line += Environment.NewLine + exception;
            if (!_queue.IsAddingCompleted) _queue.Add(line);
        }
    }
}
