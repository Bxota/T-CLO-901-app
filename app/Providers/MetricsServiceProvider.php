<?php

namespace App\Providers;

use App\Metrics\ApcuUnavailableException;
use App\Metrics\AppMetrics;
use Illuminate\Database\Events\QueryExecuted;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\ServiceProvider;
use Prometheus\CollectorRegistry;
use Prometheus\Storage\APC;
use Prometheus\Storage\InMemory;

class MetricsServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(CollectorRegistry::class, function () {
            $storage = config('metrics.storage');

            if ($storage === 'memory') {
                return new CollectorRegistry(new InMemory(), false);
            }

            if ($storage === 'apcu') {
                if (! extension_loaded('apcu') || ! apcu_enabled()) {
                    throw new ApcuUnavailableException('METRICS_STORAGE=apcu but the APCu extension is not loaded or not enabled.');
                }

                return new CollectorRegistry(new APC(), false);
            }

            throw new \InvalidArgumentException("Unknown metrics storage '{$storage}' (expected apcu or memory).");
        });

        $this->app->singleton(AppMetrics::class);
    }

    public function boot(): void
    {
        // Query timing is recorded lazily: the registry is only resolved when a
        // query runs, so a missing APCu never breaks application boot.
        DB::listen(function (QueryExecuted $query) {
            try {
                $this->app->make(AppMetrics::class)->dbQueryDuration()->observe($query->time / 1000);
            } catch (ApcuUnavailableException $e) {
                // /metrics reports the problem with a 503; requests keep working.
            }
        });
    }
}
