<?php

use App\Http\Controllers\MetricsController;
use Illuminate\Support\Facades\Route;

// Scraped by Prometheus inside the cluster only; the public HTTPRoute answers
// 403 on /metrics. No session, CSRF or throttle middleware: a scrape every
// 30 s per pod must not write a row in the sessions table.
Route::get('/metrics', MetricsController::class)->name('metrics');
