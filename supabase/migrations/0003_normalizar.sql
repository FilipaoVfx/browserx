-- Normalizacion: de `crudo` al modelo unificado `item`.
--
-- Corre en SQL y no en Go a proposito: el rastreador no necesita conocer el
-- esquema final, y un cambio de modelo se reprocesa sin volver a visitar las
-- fuentes. Las cuatro fuentes tienen formas incompatibles entre si, asi que hay
-- un extractor por fuente y un unico punto de entrada.

-- ------------------------------------------------------------------ privacidad

-- Redaccion en la normalizacion, ANTES de insertar. El trigger de `item` es la
-- red de seguridad; esta funcion es la que debe hacer el trabajo.
create or replace function redactar(t text)
returns text
language sql
immutable
parallel safe
set search_path = public, pg_temp
as $$
  select nullif(trim(
    regexp_replace(
      regexp_replace(
        regexp_replace(coalesce(t, ''),
          -- telefonos colombianos, con o sin prefijo de pais
          '(\+?57[ -]?)?\m3\d{2}[ -]?\d{3}[ -]?\d{4}\M',
          '[contacto en la fuente]', 'g'),
        -- handles tras una etiqueta de contacto. En datos reales aparecio
        -- "Usuario de WhatsApp luiibetancourt" dentro del TITULO, no del objeto
        -- contact: un identificador que ningun consumidor evita leyendo solo
        -- los campos publicos.
        '((?:usuario(?:\s+de)?\s+(?:whatsapp|telegram|instagram)|usuario|contacto)\s*:?\s+)[A-Za-z0-9._-]{3,}',
        '[contacto en la fuente]', 'gi'),
      -- arrobas y enlaces de chat
      '(@[A-Za-z0-9._-]{3,}|wa\.me/\S+|t\.me/\S+)',
      '[contacto en la fuente]', 'g')
  ), '')
$$;

comment on function redactar is
  'Redacta telefonos, handles de mensajeria y enlaces de chat. Es la primera
   linea; el trigger de item es la red de seguridad. Ningun regex cubre todo:
   la defensa de fondo es no indexar campos de contacto.';

-- ------------------------------------------------------------------ auxiliares

-- El municipio en una direccion colombiana es el PENULTIMO segmento, no el
-- segundo: "Cra 7, Pereira, Risaralda" tiene tres partes y "Dosquebradas,
-- Risaralda" solo dos. Tomar el indice 2 acertaba en la primera y devolvia el
-- departamento en la segunda.
create or replace function municipio_de(direccion text)
returns text
language sql
immutable
parallel safe
set search_path = public, pg_temp
as $$
  with p as (
    select array_remove(
      array(select trim(x) from unnest(string_to_array(coalesce(direccion,''), ',')) as x),
      '') as partes
  )
  select case
    when array_length(partes,1) is null or array_length(partes,1) < 2 then null
    else partes[array_length(partes,1) - 1]
  end
  from p
$$;

-- Punto geografico, o NULL si la fuente no trae coordenadas utiles.
create or replace function punto(lat double precision, lon double precision)
returns geography
language sql
immutable
parallel safe
set search_path = public, pg_temp
as $$
  select case
    when lat is null or lon is null then null
    when lat = 0 and lon = 0 then null            -- isla nula
    when lat not between -90 and 90 then null
    when lon not between -180 and 180 then null
    else st_point(lon, lat)::geography
  end
$$;

-- ------------------------------------------------------------------ extractores

-- Corag: {items: [...]} con location anidada y publicUrl por item.
-- contact{name,whatsapp} NUNCA se selecciona: es la fuente del riesgo que el
-- indice existe para no amplificar.
create or replace function normalizar_corag(p_crudo bigint, p_visto timestamptz)
returns int
language sql
set search_path = public, pg_temp
as $$
  with fila as (
    select jsonb_array_elements(payload -> 'items') as it
    from crudo where id = p_crudo
  ), mapeado as (
    select
      it ->> 'id'                                   as fuente_id,
      coalesce(nullif(it ->> 'title', ''), 'Sin titulo') as titulo,
      it ->> 'description'                          as resumen,
      it ->> 'type'                                 as tipo,
      it ->> 'category'                             as cat_origen,
      it -> 'location' ->> 'address'                as direccion,
      it -> 'location' ->> 'neighborhood'           as barrio,
      (it -> 'location' ->> 'latitude')::double precision  as lat,
      (it -> 'location' ->> 'longitude')::double precision as lon,
      it ->> 'publicUrl'                            as url,
      (it ->> 'createdAt')::timestamptz             as publicado,
      it ->> 'urgency'                              as urgencia
    from fila
  ), listo as (
    select
      fuente_id,
      case cat_origen
        when 'refugio'        then 'albergue'
        when 'salud'          then 'salud'
        when 'medicamentos'   then 'salud'
        when 'mascotas'       then 'mascota'
        when 'transporte'     then 'transporte'
        when 'acopio'         then 'acopio'
        when 'reconstruccion' then 'dano'
        when 'voluntariado'   then 'ofrecimiento'
        when 'otro'           then 'otro'
        else case when tipo = 'offer' then 'ofrecimiento' else 'solicitud' end
      end as categoria,
      -- Quien necesita ayuda busca ofrecimientos y sitios; quien quiere ayudar
      -- busca solicitudes. Coordinar ve todo.
      case when tipo = 'offer' then array['necesito','coordino']
           else array['ofrezco','coordino'] end as lentes,
      redactar(titulo) as titulo,
      redactar(resumen) as resumen,
      municipio_de(direccion) as municipio,
      barrio, lat, lon, url, publicado, urgencia
    from mapeado
    where fuente_id is not null and url is not null
  ), ins as (
    insert into item (fuente, fuente_id, categoria, lentes, titulo, resumen,
                      municipio, barrio, geo, url_original, visto_en, publicado_en, extra)
    select 'corag', fuente_id, categoria, lentes,
           coalesce(titulo, 'Sin titulo'), resumen,
           municipio, barrio, punto(lat, lon), url, p_visto, publicado,
           jsonb_build_object('urgencia', urgencia, 'categoria_origen', categoria)
    from listo
    on conflict (fuente, fuente_id) do update set
      categoria = excluded.categoria, lentes = excluded.lentes,
      titulo = excluded.titulo, resumen = excluded.resumen,
      municipio = excluded.municipio, barrio = excluded.barrio,
      geo = excluded.geo, visto_en = excluded.visto_en,
      publicado_en = excluded.publicado_en, extra = excluded.extra
    returning 1
  )
  select count(*)::int from ins
$$;

-- Pereira Responde: array plano. coords viene [lat, lon], no al reves.
create or replace function normalizar_pereiraresponde(p_crudo bigint, p_visto timestamptz)
returns int
language sql
set search_path = public, pg_temp
as $$
  with fila as (
    select jsonb_array_elements(payload) as it from crudo where id = p_crudo
  ), ins as (
    insert into item (fuente, fuente_id, categoria, lentes, titulo, resumen,
                      barrio, geo, url_original, visto_en, publicado_en, extra)
    select
      'pereiraresponde',
      it ->> 'id',
      case it ->> 'type'
        when 'housing' then 'dano'        -- edificaciones afectadas
        when 'road'    then 'via'
        when 'support' then 'solicitud'
        else 'otro'                       -- utility: agua, luz, servicios
      end,
      case when it ->> 'type' = 'support'
           then array['ofrezco','coordino'] else array['coordino'] end,
      redactar(coalesce(nullif(it ->> 'title', ''), 'Reporte sin titulo')),
      null,
      nullif(it ->> 'area', ''),
      punto((it -> 'coords' ->> 0)::double precision,
            (it -> 'coords' ->> 1)::double precision),
      'https://pereiraresponde.co/?reporte=' || (it ->> 'id'),
      p_visto,
      (it ->> 'createdAt')::timestamptz,
      jsonb_build_object('riesgo', it ->> 'risk', 'tipo_origen', it ->> 'type')
    from fila
    where it ->> 'id' is not null
    on conflict (fuente, fuente_id) do update set
      categoria = excluded.categoria, titulo = excluded.titulo,
      barrio = excluded.barrio, geo = excluded.geo,
      visto_en = excluded.visto_en, publicado_en = excluded.publicado_en,
      extra = excluded.extra
    returning 1
  )
  select count(*)::int from ins
$$;

-- Reporte CO: GeoJSON con propiedades en espanol. Ojo: su /api/reports (JSON)
-- usa nombres en ingles distintos; el rastreador consume el .geojson porque es
-- el que abre CORS.
--
-- Se excluyen `missing` y `rescue`: personas desaparecidas queda fuera de
-- alcance. Encontrados.co ya lo resuelve mejor y borra la biometria al instante;
-- indexarlo romperia esa promesa.
create or replace function normalizar_reporteco(p_crudo bigint, p_visto timestamptz)
returns int
language sql
set search_path = public, pg_temp
as $$
  with fila as (
    select jsonb_array_elements(payload -> 'features') as f from crudo where id = p_crudo
  ), ins as (
    insert into item (fuente, fuente_id, categoria, lentes, titulo, resumen,
                      municipio, barrio, geo, url_original, visto_en, publicado_en, extra)
    select
      'reporteco',
      f -> 'properties' ->> 'folio',
      case f -> 'properties' ->> 'categoria'
        when 'medical'  then 'salud'
        when 'damage'   then 'dano'
        when 'roads'    then 'via'
        when 'shelter'  then 'albergue'
        when 'food'     then 'solicitud'
        else 'otro'     -- water, telecoms, electricity, other
      end,
      array['coordino'],
      redactar(coalesce(nullif(f -> 'properties' ->> 'categoria_label', ''), 'Reporte')),
      redactar(f -> 'properties' ->> 'resumen'),
      nullif(f -> 'properties' ->> 'municipio', ''),
      nullif(f -> 'properties' ->> 'barrio', ''),
      punto((f -> 'geometry' -> 'coordinates' ->> 1)::double precision,
            (f -> 'geometry' -> 'coordinates' ->> 0)::double precision),
      'https://co.crafter.run/',
      p_visto,
      (f -> 'properties' ->> 'fecha')::timestamptz,
      jsonb_build_object('severidad', f -> 'properties' ->> 'severidad',
                         'departamento', f -> 'properties' ->> 'departamento')
    from fila
    where f -> 'properties' ->> 'folio' is not null
      and coalesce(f -> 'properties' ->> 'categoria', '') not in ('missing', 'rescue')
    on conflict (fuente, fuente_id) do update set
      categoria = excluded.categoria, titulo = excluded.titulo,
      resumen = excluded.resumen, municipio = excluded.municipio,
      barrio = excluded.barrio, geo = excluded.geo,
      visto_en = excluded.visto_en, publicado_en = excluded.publicado_en,
      extra = excluded.extra
    returning 1
  )
  select count(*)::int from ins
$$;

-- sigad: GeoJSON de grietas. Solo trae puntos individuales si zoom >= 16; a
-- zoom bajo devuelve clusters sin id, que no se pueden indexar.
create or replace function normalizar_sigad(p_crudo bigint, p_visto timestamptz)
returns int
language sql
set search_path = public, pg_temp
as $$
  with fila as (
    select jsonb_array_elements(payload -> 'features') as f from crudo where id = p_crudo
  ), ins as (
    insert into item (fuente, fuente_id, categoria, lentes, titulo,
                      geo, url_original, visto_en, publicado_en, extra)
    select
      'sigad',
      f -> 'properties' ->> 'id',
      'dano',                       -- todo sigad es dano estructural: sin caducidad
      array['coordino'],
      'Grieta reportada' ||
        case f -> 'properties' ->> 'ai_severity'
          when 'CRITICAL' then ' (severidad critica)'
          when 'HIGH'     then ' (severidad alta)'
          when 'MEDIUM'   then ' (severidad media)'
          when 'LOW'      then ' (severidad baja)'
          else '' end,
      punto((f -> 'geometry' -> 'coordinates' ->> 1)::double precision,
            (f -> 'geometry' -> 'coordinates' ->> 0)::double precision),
      'https://sismovision.com/',
      p_visto,
      (f -> 'properties' ->> 'created_at')::timestamptz,
      jsonb_build_object(
        'severidad_ia', f -> 'properties' ->> 'ai_severity',
        'veredicto_profesional', f -> 'properties' ->> 'professional_verdict',
        'estado', f -> 'properties' ->> 'status',
        -- La fuente marca cuando la ubicacion es aproximada. Se conserva para
        -- que la interfaz no muestre precision que el dato no tiene.
        'ubicacion_aproximada', f -> 'properties' -> 'location_is_approximate')
    from fila
    where f -> 'properties' ->> 'id' is not null
      and coalesce((f -> 'properties' ->> 'cluster')::boolean, false) = false
    on conflict (fuente, fuente_id) do update set
      titulo = excluded.titulo, geo = excluded.geo,
      visto_en = excluded.visto_en, publicado_en = excluded.publicado_en,
      extra = excluded.extra
    returning 1
  )
  select count(*)::int from ins
$$;

-- ------------------------------------------------------------------ entrada

-- Procesa todo lo pendiente de una fuente y devuelve cuantos items escribio.
create or replace function normalizar(p_fuente text)
returns int
language plpgsql
set search_path = public, pg_temp
as $$
declare
  r      record;
  total  int := 0;
  n      int;
begin
  for r in
    select id, traido_en from crudo
    where fuente = p_fuente and not procesado
    order by traido_en
  loop
    n := case p_fuente
      when 'corag'           then normalizar_corag(r.id, r.traido_en)
      when 'pereiraresponde' then normalizar_pereiraresponde(r.id, r.traido_en)
      when 'reporteco'       then normalizar_reporteco(r.id, r.traido_en)
      when 'sigad'           then normalizar_sigad(r.id, r.traido_en)
      else null
    end;

    if n is null then
      raise exception 'sin extractor para la fuente %', p_fuente;
    end if;

    update crudo set procesado = true where id = r.id;
    total := total + n;
  end loop;
  return total;
end;
$$;

comment on function normalizar is
  'Punto de entrada del rastreador. Reprocesable: basta poner procesado=false
   para volver a derivar item desde crudo, sin visitar las fuentes.';

-- El rastreador la invoca con service_role; nadie mas debe poder dispararla.
revoke execute on function normalizar(text) from anon, authenticated;
