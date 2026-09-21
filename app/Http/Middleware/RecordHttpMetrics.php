<?php

namespace App\Http\Middleware;

use App\Metrics\AppMetrics;
use Closure;
use Illuminate\Http\Request;

/**
 * Global middleware: counts every handled request and times it. Runs before
 * routing, so the matched route is read after the response is produced.
 */
class RecordHttpMetrics
{
    private const METHODS = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];

    public function handle(Request $request, Closure $next)
    {
        $start = microtime(true);
        $response = $next($request);

        if ($request->routeIs('metrics')) {
            return $response;
        }

        $route = optional($request->route())->uri() ?? 'unmatched';

        $method = $request->getMethod();
        $method = in_array($method, self::METHODS, true) ? $method : 'OTHER';

        try {
            $metrics = app(AppMetrics::class);
            $metrics->httpRequests()->inc([$route, $method, (string) $response->getStatusCode()]);
            $metrics->httpDuration()->observe(microtime(true) - $start, [$route]);
        } catch (\Throwable $e) {
            // Metrics must never turn a request into a 500. Reported by
            // /metrics (503) and the AppMetricsDown alert.
        }

        return $response;
    }
}
