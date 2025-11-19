defmodule EurekaWeb.PageControllerTest do
  use EurekaWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "GitHub Username or Organization"
    assert response =~ "Repository Name"
  end
end
