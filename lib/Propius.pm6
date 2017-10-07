#!/usr/bin/env perl6

unit module Propius;

role Ticker {
  method now() { ... };
}

class DateTimeTicker does Ticker {
  method now() {
    return DateTime.now;
  }
}

class X::Propius::LoadingFail {
  has $.key;
  method message() {
    "Specified loader return type object instead of object for key $!key";
  }
}

enum RemoveCause <Expired Explicit Replaced Size>;

class EvictionBasedCache {
  has &!loader;
  has &!removal-listener;
  has Any %!store{Any};
  has $!expire-after-write-sec;
  has $!expire-after-access-sec;
  has Ticker $ticker;
  has $!size;

  submethod BUILD(
      :&!loader! where .signature ~~ :(:$key),
      :&!removal-listener where .signature ~~ :(:$key, :$value, :$cause) = {},
      :$!expire-after-write-sec = Inf,
      :$!expire-after-access-sec = Inf,
      Ticker :$!ticker = DateTimeTicker.new,
      :$!size = Inf) { }

  method get(Any:D $key) {
    return $_ with %!store{$key};
    my $loaded = %!store{$key} = self!load($key, &!loader);
    $loaded;
  }

  multi method put(Any:D :$key, Any:D :$value) {
    my $previous = %!store{$key};
    self!publish($key, $previous, Replaced) with $previous;
    %!store{$key} = $value;
    $value;
  }

  multi method put(Any:D :$key, :&loader! where .signature ~~ :(:$key)) {
    self.put(:$key, value => self!load($key, &loader))
  }

  method invalidate(Any:D $key) {
    my $previous = %!store{$key};
    with $previous {
      self!remove($key);
      self!publish($key, $previous, Explicit);
    }
  }

  multi method invalidateAll(List:D @keys) {
    self.invalidate($_) for @keys;
  }

  multi method invalidateAll() {
    self.invalidateAll(%!store.keys);
  }

  method !load($key, &loader) {
    my $value = self!invoke-with-args((:$key), &loader);
    fail X::Propius::LoadingFail.new(:$key) without $value;
    $value;
  }

  method !publish($key, $value, RemoveCause $cause) {
    self!invoke-with-args(%(:$key, :$value, :$cause), &!removal-listener)
  }

  method !invoke-with-args(%args, &sub) {
    my $wanted = &sub.signature.params.map( *.name.substr(1) ).Set;
    my %actual = %args.grep( {$wanted{$_.key}} ).hash;
    &sub(|%actual);
  }

  method !remove($key) {
    %!store{$key}:delete;
  }
}

sub eviction-based-cache (
    :&loader! where .signature ~~ :(:$key),
    :&removal-listener where .signature ~~ :(:$key, :$value, :$cause) = sub {},
    :$expire-after-write-sec = Inf,
    :$expire-after-access-sec = Inf,
    Ticker :$ticker = DateTimeTicker.new,
    :$size = Inf
) is export {
  EvictionBasedCache.new: :&loader, :&removal-listener, :$expire-after-write-sec,
    :$expire-after-access-sec, :$ticker, :$size;
}