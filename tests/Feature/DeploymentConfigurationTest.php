<?php

namespace Tests\Feature;

use Tests\TestCase;

class DeploymentConfigurationTest extends TestCase
{
    /** @test */
    public function sessions_are_configured_for_shared_database_storage(): void
    {
        $this->assertSame('database', config('session.driver'));
        $this->assertSame('sessions', config('session.table'));
    }
}
