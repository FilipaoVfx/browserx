-- Endurecimiento de acceso publico.
--
-- crudo guarda el payload SIN normalizar: ahi viven los nombres y telefonos que
-- item nunca recibe. Si PostgREST lo expone, la redaccion del indice no sirve de
-- nada. RLS activado y CERO politicas: solo service_role (que salta RLS) entra.
alter table crudo enable row level security;
revoke all on crudo from anon, authenticated;

-- El resto es un indice publico de busqueda.
alter table item      enable row level security;
alter table categoria enable row level security;
alter table lente     enable row level security;
alter table fuente    enable row level security;

create policy item_lectura_publica      on item      for select to anon, authenticated using (true);
create policy categoria_lectura_publica on categoria for select to anon, authenticated using (true);
create policy lente_lectura_publica     on lente     for select to anon, authenticated using (true);
create policy fuente_lectura_publica    on fuente    for select to anon, authenticated using (true);

-- La vista corria con permisos de quien la creo, saltandose el RLS del que consulta.
alter view item_publico set (security_invoker = true);

-- search_path mutable permite secuestrar la resolucion de nombres.
alter function inmutable_unaccent(text)               set search_path = public, pg_temp;
alter function texto_busqueda(text, text, text, text) set search_path = public, pg_temp;
alter function item_edad_horas(item)                  set search_path = public, pg_temp;
alter function item_vencido(item)                     set search_path = public, pg_temp;
alter function sin_datos_personales()                 set search_path = public, pg_temp;

-- REVOKE por columna no basta: el GRANT de tabla ya concedio todas las columnas
-- y PostgREST seguia devolviendo ultimo_error, que puede filtrar rutas internas.
revoke select on fuente from anon, authenticated;
grant select (id, nombre, url, licencia, nivel_acceso, activa, ultimo_ok)
  on fuente to anon, authenticated;
comment on column fuente.ultimo_error is
  'Solo service_role. Puede contener rutas internas o cuerpos de error de la fuente.';

-- RLS sin politica de DELETE ya impide borrar, pero PostgREST responde 204 porque
-- el permiso existe y no hay filas visibles. Defensa en dos capas: si alguien
-- agrega una politica permisiva manana, el permiso no deberia estar ya concedido.
revoke insert, update, delete, truncate on item      from anon, authenticated;
revoke insert, update, delete, truncate on categoria from anon, authenticated;
revoke insert, update, delete, truncate on lente     from anon, authenticated;
revoke insert, update, delete, truncate on fuente    from anon, authenticated;
