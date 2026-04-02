$ErrorActionPreference = "Stop"

$port = 8000
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

Write-Output "Serving $root at http://127.0.0.1:$port/"

$contentTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".css" = "text/css; charset=utf-8"
    ".js" = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".mp3" = "audio/mpeg"
    ".png" = "image/png"
    ".jpg" = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif" = "image/gif"
    ".svg" = "image/svg+xml"
    ".ico" = "image/x-icon"
}

try {
    while ($listener.IsListening) {
        $context = $null

        try {
            $context = $listener.GetContext()
            $requestPath = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart("/"))

            if ([string]::IsNullOrWhiteSpace($requestPath)) {
                $requestPath = "index.html"
            }

            $safePath = $requestPath -replace "/", "\"
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $safePath))

            if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                $context.Response.StatusCode = 404
                $context.Response.ContentType = "text/plain; charset=utf-8"
                $context.Response.ContentLength64 = $buffer.Length
                if ($context.Request.HttpMethod -ne "HEAD") {
                    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                $context.Response.Close()
                continue
            }

            $fileInfo = Get-Item -LiteralPath $fullPath
            $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
            $contentType = $contentTypes[$extension]
            if (-not $contentType) {
                $contentType = "application/octet-stream"
            }

            $totalLength = $fileInfo.Length
            $rangeHeader = $context.Request.Headers["Range"]
            $start = 0L
            $end = [Math]::Max(0L, $totalLength - 1)
            $statusCode = 200

            if ($rangeHeader -and $rangeHeader -match 'bytes=(\d*)-(\d*)') {
                if ($matches[1]) {
                    $start = [int64]$matches[1]
                }

                if ($matches[2]) {
                    $end = [int64]$matches[2]
                }

                if ($matches[1] -and -not $matches[2]) {
                    $end = [Math]::Max(0L, $totalLength - 1)
                }

                if (-not $matches[1] -and $matches[2]) {
                    $suffixLength = [int64]$matches[2]
                    $start = [Math]::Max(0L, $totalLength - $suffixLength)
                    $end = [Math]::Max(0L, $totalLength - 1)
                }

                if ($start -gt $end -or $start -ge $totalLength) {
                    $context.Response.StatusCode = 416
                    $context.Response.Headers["Content-Range"] = "bytes */$totalLength"
                    $context.Response.Close()
                    continue
                }

                $statusCode = 206
            }

            $lengthToSend = ($end - $start) + 1

            $context.Response.StatusCode = $statusCode
            $context.Response.ContentType = $contentType
            $context.Response.ContentLength64 = $lengthToSend
            $context.Response.Headers["Accept-Ranges"] = "bytes"
            if ($statusCode -eq 206) {
                $context.Response.Headers["Content-Range"] = "bytes $start-$end/$totalLength"
            }

            if ($context.Request.HttpMethod -ne "HEAD") {
                $buffer = New-Object byte[] 65536
                $stream = [System.IO.File]::OpenRead($fullPath)

                try {
                    [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
                    $remaining = $lengthToSend

                    while ($remaining -gt 0) {
                        $chunkSize = [Math]::Min($buffer.Length, $remaining)
                        $read = $stream.Read($buffer, 0, [int]$chunkSize)
                        if ($read -le 0) {
                            break
                        }

                        $context.Response.OutputStream.Write($buffer, 0, $read)
                        $remaining -= $read
                    }
                }
                finally {
                    $stream.Close()
                }
            }

            $context.Response.Close()
        }
        catch [System.Net.HttpListenerException] {
            if ($context) {
                try { $context.Response.Close() } catch {}
            }
        }
        catch {
            if ($context) {
                try {
                    $message = [System.Text.Encoding]::UTF8.GetBytes("500 Internal Server Error")
                    $context.Response.StatusCode = 500
                    $context.Response.ContentType = "text/plain; charset=utf-8"
                    $context.Response.ContentLength64 = $message.Length
                    if ($context.Request.HttpMethod -ne "HEAD") {
                        $context.Response.OutputStream.Write($message, 0, $message.Length)
                    }
                    $context.Response.Close()
                }
                catch {}
            }

            Write-Output $_
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
