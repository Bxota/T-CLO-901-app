<?php

namespace Tests\Unit;

use App\Metrics\AppMetrics;
use Tests\TestCase;

class AppMetricsTest extends TestCase
{
    /** @test */
    public function it_is_a_singleton_with_memory_storage_in_tests()
    {
        $a = $this->app->make(AppMetrics::class);
        $b = $this->app->make(AppMetrics::class);

        $this->assertSame($a, $b);
        $this->assertSame('memory', config('metrics.storage'));
    }

    /** @test */
    public function it_registers_the_four_metric_families()
    {
        $metrics = $this->app->make(AppMetrics::class);
        $metrics->httpRequests()->inc(['api/counter/add', 'GET', '200']);
        $metrics->httpDuration()->observe(0.05, ['api/counter/add']);
        $metrics->dbQueryDuration()->observe(0.002);
        $metrics->counterValue()->set(42);

        $out = $metrics->render();

        $this->assertStringContainsString('app_http_requests_total{route="api/counter/add",method="GET",status="200"} 1', $out);
        $this->assertStringContainsString('app_http_request_duration_seconds_bucket{route="api/counter/add",le="0.1"} 1', $out);
        $this->assertStringContainsString('app_db_query_duration_seconds_count 1', $out);
        $this->assertStringContainsString('app_counter_total 42', $out);
    }
}
