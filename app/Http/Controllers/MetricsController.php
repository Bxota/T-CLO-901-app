<?php

namespace App\Http\Controllers;

use App\Metrics\ApcuUnavailableException;
use App\Metrics\AppMetrics;
use App\Models\Counter;
use Illuminate\Http\Response;
use Prometheus\RenderTextFormat;

class MetricsController extends Controller
{
    public function __invoke(): Response
    {
        try {
            $metrics = app(AppMetrics::class);
        } catch (ApcuUnavailableException $e) {
            return response('metrics storage unavailable: '.$e->getMessage()."\n", 503)
                ->header('Content-Type', 'text/plain; charset=utf-8');
        }

        try {
            $metrics->counterValue()->set((float) Counter::sum('count'));
        } catch (\Throwable $e) {
            // Database unreachable: keep serving the other families; MySQLDown
            // and the SQL histogram tell the story.
        }

        return response($metrics->render(), 200)
            ->header('Content-Type', RenderTextFormat::MIME_TYPE.'; charset=utf-8');
    }
}
