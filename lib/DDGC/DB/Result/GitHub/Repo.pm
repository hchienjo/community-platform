package DDGC::DB::Result::GitHub::Repo;
# ABSTRACT:

use Moose;
use MooseX::NonMoose;
extends 'DDGC::DB::Base::Result';
use DBIx::Class::Candy;
use namespace::autoclean;

table 'github_pull';

column id => {
  data_type => 'bigint',
  is_auto_increment => 1,
};
primary_key 'id';

column github_id => {
  data_type => 'bigint',
  is_nullable => 0,
};

column full_name => {
  data_type => 'text',
  is_nullable => 0,
};

column description => {
  data_type => 'text',
  is_nullable => 0,
};

column created => {
  data_type => 'timestamp with time zone',
  set_on_create => 1,
};

column updated => {
  data_type => 'timestamp with time zone',
  set_on_create => 1,
  set_on_update => 1,
};

no Moose;
__PACKAGE__->meta->make_immutable;