defmodule Moebius.DocumentCommand do
  defstruct pid: nil,
            table_name: nil,
            type: :select,
            sql: nil,
            params: [],
            json_field: "body",
            where: "",
            order: "",
            limit: "",
            offset: "",
            search_fields: [],
            searched?: false,
            group_by: nil,
            conn: nil
end
