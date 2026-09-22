<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class EnvironmentBadgeTest extends TestCase
{
    use RefreshDatabase;

    /** @test */
    public function staging_shows_a_banner(): void
    {
        config(['app.deploy_env' => 'staging']);

        $this->get('/')
            ->assertOk()
            ->assertSee('id="env-banner"', false)
            ->assertSee('STAGING');
    }

    /** @test */
    public function production_shows_no_banner(): void
    {
        config(['app.deploy_env' => 'production']);

        $this->get('/')
            ->assertOk()
            ->assertDontSee('id="env-banner"', false)
            ->assertDontSee('STAGING');
    }

    /** @test */
    public function the_deployed_version_and_environment_are_shown(): void
    {
        config(['app.deploy_env' => 'production', 'app.version' => '1.2.0']);

        $this->get('/')
            ->assertOk()
            ->assertSee('version 1.2.0')
            ->assertSee('production');
    }
}
