from probe_lab.notes import describe


def test_describe_names_the_sign():
    assert describe(1) == "positive"
    assert describe(0) == "non-positive"
