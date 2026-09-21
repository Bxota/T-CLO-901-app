<?php

namespace App\Http\Middleware;

use App\Metrics\ApcuUnavailableException;
use App\Metrics\AppMetrics;
use Closure;
use Illuminate\Http\Request;

/**
 * Global middleware: counts every handled request and times it. Runs before
 * routing, so the matched route is read after the response is produced.
 */
class RecordHttpMetrics
{
    public function handle(Request $request, Closure $next)
    {
        $start = microtime(true);
        $response = $next($request);

        if ($request->is('metrics')) {
            return $response;
        }

        $route = optional($request->route())->uri() ?? 'unmatched';

        try {
            $metrics = app(AppMetrics::class);
            $metrics->httpRequests()->inc([$route, $request->getMethod(), (string) $response->getStatusCode()]);
            $metrics->httpDuration()->observe(microtime(true) - $start, [$route]);
        } catch (ApcuUnavailableException $e) {
            // Reported by /metrics (503) and the AppMetricsDown alert.
        }

        return $response;
    }
}
