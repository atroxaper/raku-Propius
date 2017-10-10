#!/usr/bin/env perl6

unit module Propius;

use Propius::Linked;

role Ticker {
  method now( --> Int:D) { ... };
}

class DateTimeTicker does Ticker {
  method now() {
    return DateTime.now.posix;
  }
}

class X::Propius::LoadingFail {
  has $.key;
  method message() {
    "Specified loader return type object instead of object for key $!key";
  }
}

enum RemoveCause <Expired Explicit Replaced Size>;

enum ActionType <Access Write>;

class ValueStore {
  has $.key;
  has $.value is rw;
  has Propius::Linked::Node %.nodes{ActionType};
  has Int %.last-action-at{ActionType};

  multi method new(:$key!, :$value!, :@types!) {
    my $blessed = self.new(:$key, :$value);
    for @types -> $type {
      $blessed.nodes{$type} = Propius::Linked::Node.new: value => $blessed;
    }
    $blessed;
  }

  method move-to-head-for(@types, Propius::Linked::Chain %chains, Int $now) {
    for %!nodes.keys.grep: * ~~ any(@types) {
      %chains{$_}.move-to-head(%!nodes{$_});
      %!last-action-at{$_} = $now;
    }
  }

  method remove-nodes() {
    .remove() for %!nodes.values;
  }

  method last-at(ActionType $type) {
    %!last-action-at{$type};
  }
}

class EvictionBasedCache {
  has &!loader;
  has &!removal-listener;
  has Any %!expire-after-sec{ActionType};
  has Ticker $ticker;
  has $!size;

  has ValueStore %!store{Any};
  has Propius::Linked::Chain %!chains{ActionType};

  submethod BUILD(
      :&!loader! where .signature ~~ :(:$key),
      :&!removal-listener where .signature ~~ :(:$key, :$value, :$cause) = {},
      :%!expire-after-sec = :{(Access) => Inf, (Write)  => Inf},
      Ticker :$!ticker = DateTimeTicker.new,
      :$!size = Inf) {
    %!chains{Access} = Propius::Linked::Chain.new;
    if %!expire-after-sec{Write} !=== Inf {
      %!chains{Write} = Propius::Linked::Chain.new;
    }
  }

  method get(Any:D $key) {
    my $value = %!store{$key};
    with $value {
      $value.move-to-head-for((Access,), %!chains, $!ticker.now);
      return $value.value
    }
    self.put(:$key, :&!loader);
    %!store{$key}.value;
  }

  multi method put(Any:D :$key, Any:D :$value) {
    $.clean-up();
    my $previous = %!store{$key};
    my $move;
    with $previous {
      self!publish($key, $previous.value, Replaced);
      $previous.value = $value;
      $move = $previous;
    } else {
      my $wrap = self!wrap-value($key, $value);
      %!store{$key} = $wrap;
      $move = $wrap;
    }
    $move.move-to-head-for(ActionType::.values, %!chains, $!ticker.now);
  }

  multi method put(Any:D :$key, :&loader! where .signature ~~ :(:$key)) {
    self.put(:$key, value => self!load($key, &loader))
  }

  method invalidate(Any:D $key) {
    self!remove($key, Explicit);
  }

  multi method invalidateAll(List:D @keys) {
    self.invalidate($_) for @keys;
  }

  multi method invalidateAll() {
    self.invalidateAll(%!store.keys);
  }

  method elems() {
    %!store.elems;
  }

  method clean-up() {
    while $.elems >= $!size {
      self!remove(%!chains{Access}.last().value.key, Size);
    }
    my $now = $!ticker.now;
    for %!chains.kv -> $type, $chain {
      my $life-time = %!expire-after-sec{$type};
      next if $life-time === Inf;

      my $wrap = $chain.last.value;
      while $wrap.DEFINITE && $wrap.last-at($type) + $life-time <= $now {
        self!remove($wrap.key, Expired);
        $wrap = $chain.last.value;
      }
    }
  }

  method !wrap-value($key, $value) {
    ValueStore.new: :$key, :$value, types => %!chains.keys;
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

  method !remove($key, $cause) {
    my $previous = %!store{$key};
    with $previous {
      %!store{$key}:delete;
      $previous.remove-nodes();
      self!publish($key, $previous.value, $cause);
    }
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
  EvictionBasedCache.new: :&loader, :&removal-listener, :$ticker, :$size,
    expire-after-sec => :{(Access) => $expire-after-access-sec,
      (Write)  => $expire-after-write-sec};
}