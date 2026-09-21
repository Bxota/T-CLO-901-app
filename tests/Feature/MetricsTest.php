<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class MetricsTest extends TestCase
{
    use RefreshDatabase;

    /** @test */
    public function metrics_endpoint_exposes_the_counter_gauge()
    {
        $this->get('/api/counter/add');
        $this->get('/api/counter/add');

        $response = $this->get('/metrics');

        $response->assertStatus(200);
        $response->assertHeader('Content-Type', 'text/plain; version=0.0.4; charset=utf-8');
        $this->assertStringContainsString('app_counter_total 2', $response->getContent());
        $this->assertStringContainsString('app_db_query_duration_seconds_count', $response->getContent());
    }

    /** @test */
    public function metrics_endpoint_does_not_start_a_session()
    {
        $response = $this->get('/metrics');

        $response->assertStatus(200);
        $response->assertCookieMissing(config('session.cookie'));
    }

    /** @test */
    public function metrics_endpoint_returns_503_when_apcu_storage_is_unavailable()
    {
        if (extension_loaded('apcu') && apcu_enabled()) {
            $this->markTestSkipped('APCu is available here; the 503 path cannot be exercised.');
        }

        config(['metrics.storage' => 'apcu']);

        $response = $this->get('/metrics');

        $response->assertStatus(503);
        $this->assertStringContainsString('metrics storage unavailable', $response->getContent());
    }
}
