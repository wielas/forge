"""Every example asserts the exact slug, so each line of slugify is observed."""

from pytest_bdd import given, parsers, scenarios, then, when

from probe_lab.slug import slugify

scenarios("../features/slug.feature")


@given(parsers.parse('the title "{title}"'), target_fixture="title")
def title(title):
    return title


@when("it is slugified", target_fixture="slug")
def slug(title):
    return slugify(title)


@then(parsers.parse('the slug is "{expected}"'))
def is_slug(slug, expected):
    assert slug == expected
