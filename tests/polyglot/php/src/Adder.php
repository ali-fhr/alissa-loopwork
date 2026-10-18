<?php

declare(strict_types=1);

namespace Smoke;

/** The polyglot image's PHP smoke sample. */
final class Adder
{
    public static function add(int $a, int $b): int
    {
        return $a + $b;
    }
}
