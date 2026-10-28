"""client-info gives the owner in Cyrillic; statements give counterName in Latin."""
from app.core.translit import same_person, translit_ua


def test_kmu_2010_basics():
    assert translit_ua("Шевченко Тарас") == "shevchenko taras"
    assert translit_ua("Юрій Їжакевич") == "yurii yizhakevych"
    assert translit_ua("Згурський") == "zghurskyi"
    assert translit_ua("Щербань") == "shcherban"


def test_same_person_crosses_scripts_and_word_order():
    assert same_person("Шевченко Тарас", "Shevchenko Taras")
    assert same_person("Шевченко Тарас", "Taras Shevchenko")
    assert same_person("Шевченко Тарас", "ШЕВЧЕНКО ТАРАС")


def test_different_person_with_shared_surname_is_not_the_owner():
    assert not same_person("Шевченко Тарас", "Оксана Шевченко")
    assert not same_person("Шевченко Тарас", "Oksana Shevchenko")


def test_missing_names_never_match():
    assert not same_person("Шевченко Тарас", None)
    assert not same_person("", "Shevchenko Taras")
