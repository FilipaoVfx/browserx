-- browserx: indice federado del ecosistema de ayuda
--
-- Dos capas a proposito:
--   crudo  -> payload tal como lo devolvio la fuente, sin interpretar
--   item   -> modelo unificado, derivado de crudo por SQL
--
-- Separarlas permite re-normalizar tras un cambio de modelo sin volver a visitar
-- las fuentes, y deja al rastreador sin necesidad de conocer el esquema final.

create extension if not exists pg_trgm;
create extension if not exists unaccent;
create extension if not exists postgis;

-- ---------------------------------------------------------------- utilidades

-- unaccent() es STABLE, no IMMUTABLE, porque depende del diccionario instalado.
-- Postgres rechaza funciones no inmutables en columnas generadas y en indices,
-- asi que se envuelve fijando el diccionario de forma explicita.
create or replace function inmutable_unaccent(text)
returns text
language sql
immutable
strict
parallel safe
as $$ select public.unaccent('public.unaccent', $1) $$;

-- Texto normalizado para busqueda: sin tildes y en minusculas.
create or replace function texto_busqueda(titulo text, resumen text, municipio text, barrio text)
returns tsvector
language sql
immutable
parallel safe
as $$
  select
    setweight(to_tsvector('spanish', inmutable_unaccent(coalesce(titulo, ''))), 'A') ||
    setweight(to_tsvector('spanish', inmutable_unaccent(coalesce(municipio, ''))), 'B') ||
    setweight(to_tsvector('spanish', inmutable_unaccent(coalesce(barrio, ''))), 'B') ||
    setweight(to_tsvector('spanish', inmutable_unaccent(coalesce(resumen, ''))), 'C')
$$;

-- ---------------------------------------------------------------- catalogos

-- Las cinco categorias del directorio de Corag, mas el umbral de caducidad.
-- horas NULL = el dato no envejece. Daño estructural describe un hecho fisico,
-- no un estado operativo: un edificio dañado sigue dañado.
create table categoria (
  id      text primary key,
  familia text not null check (familia in ('matching','damage','logistics','pets','people')),
  horas   int,
  check (horas is null or horas > 0)
);

insert into categoria (id, familia, horas) values
  ('acopio',        'logistics',  6),
  ('inventario',    'logistics',  6),
  ('solicitud',     'matching',  12),
  ('ofrecimiento',  'matching',  12),
  ('albergue',      'logistics', 24),
  ('salud',         'logistics', 24),
  ('transporte',    'logistics', 12),
  ('via',           'damage',    24),
  ('dano',          'damage',    null),
  ('mascota',       'pets',      48),
  ('persona',       'people',    24),
  ('otro',          'matching',  24);

-- Las lentes del buscador. Sirven a los tres publicos sin priorizar a ninguno
-- en el modelo: cada una define su propio orden sobre el mismo indice.
create table lente (
  id     text primary key,
  nombre text not null
);

insert into lente (id, nombre) values
  ('necesito',  'Necesito ayuda'),
  ('ofrezco',   'Quiero ayudar'),
  ('coordino',  'Estoy coordinando');

-- ---------------------------------------------------------------- fuentes

create table fuente (
  id           text primary key,
  nombre       text not null,
  url          text not null,
  endpoint     text not null,
  licencia     text,
  nivel_acceso int not null,               -- escalera del spec, 1 = API documentada
  activa       boolean not null default true,
  ultimo_ok    timestamptz,
  ultimo_error text,
  check (nivel_acceso between 1 and 7)
);

insert into fuente (id, nombre, url, endpoint, nivel_acceso) values
  ('corag',           'Corag Ayuda Directa', 'https://ayuda.corag.app',
   'https://ayuda.corag.app/api/public/v1/help?view=list', 1),
  ('pereiraresponde', 'Pereira Responde',    'https://pereiraresponde.co',
   'https://pereiraresponde.co/api/reports', 2),
  ('reporteco',       'Reporte CO',          'https://co.crafter.run',
   'https://co.crafter.run/api/reports.geojson', 2),
  ('sigad',           'SismoVision',         'https://sismovision.com',
   'https://api.sigad.co/api/v1/map/points/', 2);

-- ---------------------------------------------------------------- crudo

create table crudo (
  id        bigserial primary key,
  fuente    text not null references fuente(id),
  traido_en timestamptz not null default now(),
  hash      text not null,      -- sha256 del payload: evita reprocesar lo identico
  payload   jsonb not null,
  procesado boolean not null default false
);

-- Un payload identico al anterior no genera fila nueva: la fuente no cambio.
create unique index crudo_fuente_hash on crudo (fuente, hash);
create index crudo_pendiente on crudo (fuente, traido_en desc) where not procesado;

-- ---------------------------------------------------------------- item

create table item (
  id             uuid primary key default gen_random_uuid(),
  fuente         text not null references fuente(id),
  fuente_id      text not null,               -- id original, para deduplicar
  categoria      text not null references categoria(id),
  lentes         text[] not null default '{}',
  titulo         text not null,
  resumen        text,
  municipio      text,
  barrio         text,
  geo            geography(point, 4326),
  url_original   text not null,               -- siempre se enlaza a la fuente
  visto_en       timestamptz not null,        -- cuando lo leyo el rastreador
  publicado_en   timestamptz,                 -- cuando lo publico la fuente
  extra          jsonb not null default '{}', -- campos propios de cada categoria
  busqueda       tsvector generated always as
                 (texto_busqueda(titulo, resumen, municipio, barrio)) stored,
  unique (fuente, fuente_id)
);

comment on table item is
  'Modelo unificado. SIN datos de contacto: nombre, telefono y direccion exacta
   nunca entran al indice. El contacto se ve al abrir la ficha en la fuente.';

create index item_busqueda   on item using gin (busqueda);
create index item_titulo_trg on item using gin (inmutable_unaccent(titulo) gin_trgm_ops);
create index item_geo        on item using gist (geo);
create index item_categoria  on item (categoria, visto_en desc);
create index item_lentes     on item using gin (lentes);

-- ---------------------------------------------------------------- frescura

-- Edad del dato y si vencio, segun el umbral de su categoria.
-- Nada se oculta jamas: vencido solo significa que baja en el orden.
create or replace function item_edad_horas(i item)
returns numeric
language sql
stable
as $$ select round(extract(epoch from (now() - i.visto_en)) / 3600.0, 1) $$;

create or replace function item_vencido(i item)
returns boolean
language sql
stable
as $$
  select case
    when c.horas is null then false
    else i.visto_en < now() - make_interval(hours => c.horas)
  end
  from categoria c where c.id = i.categoria
$$;

-- Vista de lectura para el buscador: agrega edad y vencimiento ya calculados.
create view item_publico as
select
  i.*,
  item_edad_horas(i) as edad_horas,
  item_vencido(i)    as vencido,
  c.horas            as umbral_horas,
  c.familia
from item i
join categoria c on c.id = i.categoria;

-- ---------------------------------------------------------------- privacidad

-- Guardarrail, no sustituto de la redaccion en la normalizacion: si un telefono
-- colombiano llega al indice, la insercion falla en vez de publicarlo.
create or replace function sin_datos_personales()
returns trigger
language plpgsql
as $$
declare
  patron text := '(\+?57[ -]?)?3\d{2}[ -]?\d{3}[ -]?\d{4}';
begin
  if new.titulo ~ patron or coalesce(new.resumen, '') ~ patron then
    raise exception 'item %/% contiene un telefono: la normalizacion debe redactarlo antes de insertar',
      new.fuente, new.fuente_id;
  end if;
  return new;
end;
$$;

create trigger item_sin_datos_personales
  before insert or update on item
  for each row execute function sin_datos_personales();
