<?php

return [
    // 'apcu' in the container image (shared across Apache workers of one pod),
    // 'memory' for the test suite. Any other value is rejected at boot.
    'storage' => env('METRICS_STORAGE', 'apcu'),
];
