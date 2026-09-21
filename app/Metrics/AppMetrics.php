<?php

namespace App\Metrics;

use Prometheus\CollectorRegistry;
use Prometheus\Counter;
use Prometheus\Gauge;
use Prometheus\Histogram;
use Prometheus\RenderTextFormat;

/**
 * The application's Prometheus metric families. Registering a family twice
 * with the same name returns the existing one, so the accessors are safe to
 * call on every request.
 */
class AppMetrics
{
    public const NAMESPACE = 'app';

    private CollectorRegistry $registry;

    public function __construct(CollectorRegistry $registry)
    {
        $this->registry = $registry;
    }

    public function registry(): CollectorRegistry
    {
        return $this->registry;
    }

    public function httpRequests(): Counter
    {
        return $this->registry->getOrRegisterCounter(
            self::NAMESPACE,
            'http_requests_total',
            'HTTP requests handled by Laravel, by route, method and status.',
            ['route', 'method', 'status']
        );
    }

    public function httpDuration(): Histogram
    {
        return $this->registry->getOrRegisterHistogram(
            self::NAMESPACE,
            'http_request_duration_seconds',
            'Wall-clock duration of HTTP requests handled by Laravel.',
            ['route'],
            [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
        );
    }

    public function dbQueryDuration(): Histogram
    {
        return $this->registry->getOrRegisterHistogram(
            self::NAMESPACE,
            'db_query_duration_seconds',
            'Duration of SQL queries executed through Eloquent/PDO.',
            [],
            [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1]
        );
    }

    public function counterValue(): Gauge
    {
        return $this->registry->getOrRegisterGauge(
            self::NAMESPACE,
            'counter_total',
            'Current business counter value (sum of the counters table).'
        );
    }

    public function render(): string
    {
        return (new RenderTextFormat())->render($this->registry->getMetricFamilySamples());
    }
}
