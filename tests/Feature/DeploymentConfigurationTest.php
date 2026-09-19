<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Session\Store;
use Tests\TestCase;

class DeploymentConfigurationTest extends TestCase
{
    use RefreshDatabase;

    /** @test */
    public function sessions_are_configured_for_shared_database_storage(): void
    {
        $this->assertSame('database', config('session.driver'));
        $this->assertSame('sessions', config('session.table'));

        $session = $this->app['session']->driver();
        $session->put('deployment_probe', 'persisted');
        $session->save();

        $reloadedSession = new Store(config('session.cookie'), $session->getHandler());
        $reloadedSession->setId($session->getId());
        $reloadedSession->start();

        $this->assertSame('persisted', $reloadedSession->get('deployment_probe'));
    }
}
