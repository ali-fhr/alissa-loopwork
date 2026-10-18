<?php

declare(strict_types=1);

namespace Smoke\Tests;

use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;
use Smoke\Adder;

final class AdderTest extends TestCase
{
    #[Test]
    public function addsTwoNumbers(): void
    {
        self::assertSame(5, Adder::add(2, 3));
    }
}
